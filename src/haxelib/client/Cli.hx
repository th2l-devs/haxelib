/*
 * Copyright (C)2005-2016 Haxe Foundation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package haxelib.client;

enum OutputMode {
	Quiet;
	Debug;
	None;
}

enum abstract DefaultAnswer(Null<Bool>) to Null<Bool> {
	final Always = true;
	final Never = false;
	final None = null;
}

private enum abstract Unit(String) to String {
	final MB = "MB";
	final KB = "KB";

	public static function convertFromBytes(value:Int, unit:Unit):Float{
		final by = switch unit {
			case MB: 1000000;
			case KB: 1000;
			default: 1;
		}
		// 12.34 precision.
		return Math.round((value/by) * 100) / 100;
	}

	public static function getUnitFor(value:Int):Unit {
		if ((value / 1000000) > 1)
			return MB;
		return KB;
	}
}

class Cli {
	public static var defaultAnswer(null, default):DefaultAnswer = None;
	public static var mode:OutputMode = None;

	public static function ask(question:String):Bool {
		if (defaultAnswer != None)
			return defaultAnswer;

		while (true) {
			Sys.print(question + " [y/n/a] ? ");
			try {
				switch (Sys.stdin().readLine()) {
					case "n": return false;
					case "y": return true;
					case "a": return defaultAnswer = Always;
				}
			} catch (e:haxe.io.Eof) {
				Sys.println("n");
				return false;
			}
		}
		return false;
	}

	public static function getSecretInput(prompt:String):String {
		Sys.print('$prompt : ');
		final s = new StringBuf();
		do
			switch Sys.getChar(false) {
				case 10, 13:
					break;
				case 0: // ignore (windows bug)
				case c:
					s.addChar(c);
			} while (true);
		Sys.println("");
		return s.toString();
	}

	//
	// ── Progress rendering (pip / rich style) ────────────────────────────────
	//
	// A solid `━` line that fills the terminal width, with the completed part
	// drawn in colour. Colours are disabled by the `NO_COLOR` convention; the
	// box-drawing glyph is used only when the console is UTF-8 (auto-detected),
	// otherwise it falls back to ASCII so non-UTF-8 consoles don't get mojibake.
	// `HAXELIB_NO_UNICODE` / `HAXELIB_UNICODE` force the glyph off / on.
	//

	static final ESC = "\x1b";

	//
	// Colour codes. Deliberately simple/basic ANSI (16-colour + a couple of
	// 256-colour greys) rather than 24-bit truecolor, since classic Windows
	// consoles render these far more reliably.
	//
	static inline final C_GRAY = "38;5;7"; // info
	static inline final C_DIM = "38;5;8"; // debug / credit / bar track
	static inline final C_YELLOW = "33"; // warn
	static inline final C_RED = "31"; // error
	static inline final C_MAGENTA = "38;5;205"; // bar fill (256-colour pink)

	/**
		Whether ANSI colours are emitted. On by default; set `NO_COLOR` to disable.
		On Windows we still enable virtual-terminal mode (see `detectConsole`) so
		the codes actually render instead of printing raw.
	**/
	static final colorOn:Bool = Sys.getEnv("NO_COLOR") == null;

	static inline function useColor():Bool
		return colorOn;

	/** Frame counter used to animate the pulse shown when the total is unknown. **/
	static var pulseFrame = 0;

	/** Length (in visible columns) of the last status line, to blank leftovers. **/
	static var lastVisibleLen = 0;

	static var cachedWidth = 0;
	static var cachedUnicode:Null<Bool> = null;

	/** Whether the box-drawing bar glyph is safe to use on this console. **/
	static function unicodeEnabled():Bool {
		detectConsole();
		return cachedUnicode;
	}

	static inline function barFill():String
		return unicodeEnabled() ? "━" : "=";

	static inline function barTrack():String
		return unicodeEnabled() ? "━" : "-";

	/** Formats a byte count as a human readable string, e.g. `2.1 MB`. **/
	static function formatBytes(bytes:Int):String {
		final unit = Unit.getUnitFor(bytes);
		return '${Unit.convertFromBytes(bytes, unit)} $unit';
	}

	/** Formats `cur`/`max` bytes sharing a single unit, e.g. `2.1/4.5 MB`. **/
	static function formatBytesPair(cur:Int, max:Int):String {
		final unit = Unit.getUnitFor(max);
		return '${Unit.convertFromBytes(cur, unit)}/${Unit.convertFromBytes(max, unit)} $unit';
	}

	/** Formats a duration in seconds as `h:mm:ss`, e.g. `0:00:07` (pip style). **/
	static function formatClock(seconds:Float):String {
		var total = Std.int(seconds);
		if (total < 0)
			total = 0;
		final h = Std.int(total / 3600);
		final m = Std.int((total % 3600) / 60);
		final s = total % 60;
		inline function pad(n:Int) return n < 10 ? '0$n' : '$n';
		return '$h:${pad(m)}:${pad(s)}';
	}

	static inline function paint(code:String, s:String):String {
		if (!useColor())
			return s;
		detectConsole(); // make sure VT mode is on (Windows) before we emit codes
		return '$ESC[${code}m$s$ESC[0m';
	}

	/** Repeats `s` `n` times (safe for multi-byte glyphs). **/
	static function repeatStr(s:String, n:Int):String {
		final buf = new StringBuf();
		for (_ in 0...n)
			buf.add(s);
		return buf.toString();
	}

	static function terminalWidth():Int {
		detectConsole();
		return cachedWidth;
	}

	/**
		One-time console probe, run before any styled output. On Windows it:

		- enables virtual-terminal (ANSI) processing on the real console via
		  `CONOUT$`, so escape codes are rendered instead of printed raw;
		- reports the visible width and output code page (so we know whether the
		  UTF-8 bar glyph is safe), or nothing at all when there is no console
		  (output redirected to a file/pipe) - in which case colour stays off.

		Falls back to 80 columns / ASCII / no colour if anything fails.
	**/
	static function detectConsole():Void {
		if (cachedUnicode != null)
			return;
		final isWindows = Sys.systemName() == "Windows";
		cachedWidth = 80;
		// unix terminals are UTF-8; on Windows default to ASCII unless proven otherwise
		cachedUnicode = !isWindows;
		if (Sys.getEnv("HAXELIB_NO_UNICODE") != null)
			cachedUnicode = false;
		final forceUnicode = Sys.getEnv("HAXELIB_UNICODE") != null;
		if (forceUnicode)
			cachedUnicode = true;

		inline function acceptWidth(n:Null<Int>):Bool {
			if (n != null && n >= 20) {
				cachedWidth = n > 200 ? 200 : n;
				return true;
			}
			return false;
		}

		var haveWidth = acceptWidth(Std.parseInt(Sys.getEnv("COLUMNS") ?? ""));
		try {
			if (isWindows) {
				// enable ANSI on the real console (CONOUT$), then print the visible
				// width and the output code page - or nothing if there's no console.
				final csharp =
					"[DllImport(\"kernel32.dll\",SetLastError=true)]public static extern System.IntPtr CreateFileW(string n,uint a,uint s,System.IntPtr se,uint d,uint f,System.IntPtr t);"
					+ "[DllImport(\"kernel32.dll\")]public static extern bool GetConsoleMode(System.IntPtr h,out uint m);"
					+ "[DllImport(\"kernel32.dll\")]public static extern bool SetConsoleMode(System.IntPtr h,uint m);";
				final psCmd =
					"$s='" + csharp + "';"
					+ "try{$k=Add-Type -MemberDefinition $s -Name Vt -Namespace HxVt -PassThru -ErrorAction Stop;"
					+ "$h=$k::CreateFileW('CONOUT$',0x40000000,3,[System.IntPtr]::Zero,3,0,[System.IntPtr]::Zero);"
					+ "$m=0;if($k::GetConsoleMode($h,[ref]$m)){[void]$k::SetConsoleMode($h,($m -bor 4))}}catch{};"
					+ "try{[Math]::Min([Console]::WindowWidth,[Console]::BufferWidth)}catch{'x'};"
					+ "try{[Console]::OutputEncoding.CodePage}catch{'x'}";
				final p = new sys.io.Process("powershell", ["-NoProfile", "-NonInteractive", "-Command", psCmd]);
				final out = StringTools.replace(p.stdout.readAll().toString(), "\r", "");
				p.close();
				final lines = out.split("\n").filter(l -> StringTools.trim(l) != "");
				final width = lines.length >= 1 ? Std.parseInt(StringTools.trim(lines[0])) : null;
				final consolePresent = width != null && width > 0;
				if (!haveWidth && consolePresent)
					acceptWidth(width);
				// code page 65001 == UTF-8; only then are box-drawing glyphs safe
				if (!forceUnicode && Sys.getEnv("HAXELIB_NO_UNICODE") == null && lines.length >= 2)
					cachedUnicode = Std.parseInt(StringTools.trim(lines[1])) == 65001;
			} else if (!haveWidth) {
				final p = new sys.io.Process("stty", ["size"]);
				final out = p.stdout.readAll().toString();
				p.close();
				final parts = StringTools.trim(out).split(" ");
				if (parts.length == 2)
					acceptWidth(Std.parseInt(parts[1]));
			}
		} catch (_:Dynamic) {}
	}

	/** Renders a solid bar of `width` columns filled to `fraction` (0-1). **/
	static function solidBar(fraction:Float, width:Int):String {
		if (fraction < 0) fraction = 0;
		if (fraction > 1) fraction = 1;
		final filled = Math.round(fraction * width);
		// filled part in pink, remaining track in dim grey, matching pip
		return paint(C_MAGENTA, repeatStr(barFill(), filled))
			+ paint(C_DIM, repeatStr(barTrack(), width - filled));
	}

	/** Renders an indeterminate "pulse" bar with a block sweeping across it. **/
	static function pulseBar(width:Int):String {
		final seg = Std.int(width / 4);
		final pos = pulseFrame++ % (width + seg) - seg;
		final glyph = barFill();
		final buf = new StringBuf();
		for (i in 0...width)
			buf.add(paint(i >= pos && i < pos + seg ? C_MAGENTA : C_DIM, glyph));
		return buf.toString();
	}

	/**
		Draws an indented bar followed by `stats` across the full terminal width.

		`statsVisibleLen` is the printable length of `stats` (excluding any colour
		codes) so the line can be cleared correctly on the next redraw.
	**/
	static function drawBar(bar:String, barWidth:Int, stats:String, statsVisibleLen:Int, finished:Bool) {
		final line = "\r   " + bar + " " + stats;
		final visibleLen = 3 + barWidth + 1 + statsVisibleLen;
		Sys.print(line);
		if (lastVisibleLen > visibleLen)
			Sys.print(repeatStr(" ", lastVisibleLen - visibleLen));
		if (finished) {
			Sys.print("\n");
			lastVisibleLen = 0;
		} else {
			lastVisibleLen = visibleLen;
		}
	}

	/** Preferred (compact) width of the bar itself, in columns. **/
	static inline final BAR_WIDTH = 28;

	static inline function barWidthFor(reserve:Int):Int {
		// keep the bar short and fixed; only shrink further if the terminal is too
		// narrow to fit bar + stats without reaching the last column (a full-width
		// line would auto-wrap and the \r redraw would then pile frames up).
		final maxForTerminal = terminalWidth() - 6 - reserve;
		final w = BAR_WIDTH < maxForTerminal ? BAR_WIDTH : maxForTerminal;
		return w < 10 ? 10 : w;
	}

	public static function printInstallStatus(_, current:Int, total:Int) {
		if (current == total) {
			// clear the bar once installation finishes
			if (lastVisibleLen > 0) {
				Sys.print("\r" + repeatStr(" ", lastVisibleLen) + "\r");
				lastVisibleLen = 0;
			}
			return;
		}
		final fraction = current / total;
		final stats = '${Std.int(fraction * 100)}% (${current + 1}/$total files)';
		final width = barWidthFor(stats.length);
		drawBar(solidBar(fraction, width), width, stats, stats.length, false);
	}

	public static function printUploadStatus(pos:Int, total:Int) {
		final fraction = pos / total;
		final stats = '${Std.int(fraction * 100)}% ${formatBytesPair(pos, total)}';
		final width = barWidthFor(stats.length);
		drawBar(solidBar(fraction, width), width, stats, stats.length, false);
	}

	public static function printDownloadStatus(label:String, finished:Bool, cur:Int, max:Null<Int>, downloaded:Int, time:Float) {
		final speed = time > 0 ? downloaded / time : 0;
		final speedStr = formatBytes(Std.int(speed)) + "/s";
		// reserve a fixed slice for the stats so the bar length never jitters
		final reserve = 40;

		if (finished && max != null) {
			final stats = '${formatBytesPair(max, max)} $speedStr eta ${formatClock(0)}';
			final width = barWidthFor(reserve);
			drawBar(solidBar(1, width), width, StringTools.rpad(stats, " ", reserve), reserve, true);
		} else if (finished) {
			final stats = '${formatBytes(downloaded)} $speedStr in ${formatClock(time)}';
			final width = barWidthFor(reserve);
			drawBar(solidBar(1, width), width, StringTools.rpad(stats, " ", reserve), reserve, true);
		} else if (max == null) {
			// total size unknown: sweeping pulse + running byte count
			final stats = '${formatBytes(cur)} $speedStr ${formatClock(time)}';
			final width = barWidthFor(reserve);
			drawBar(pulseBar(width), width, StringTools.rpad(stats, " ", reserve), reserve, false);
		} else {
			final fraction = cur / max;
			final etaStr = speed > 0 ? formatClock((max - cur) / speed) : "0:00:00";
			final stats = '${formatBytesPair(cur, max)} $speedStr eta $etaStr';
			final width = barWidthFor(reserve);
			drawBar(solidBar(fraction, width), width, StringTools.rpad(stats, " ", reserve), reserve, false);
		}
	}

	//
	// ── Git progress ─────────────────────────────────────────────────────────
	//
	// git writes a `\r`-updated progress meter to stderr; we buffer those chunks,
	// pull the phase + percentage out of them and render our own bar instead of
	// git's raw "Receiving objects: 42% (…)" lines. Non-progress lines (info and
	// errors) are dropped here - on failure the full stderr is surfaced anyway.
	//

	static var gitBuf = "";
	static final gitPhaseEReg = ~/(Receiving objects|Resolving deltas|Compressing objects|Counting objects):\s+(\d+)% \((\d+)\/(\d+)\)/;

	public static function printVcsProgress(chunk:String) {
		gitBuf += chunk;
		// git separates progress updates with \r and finished lines with \n
		while (true) {
			final rIdx = gitBuf.indexOf("\r");
			final nIdx = gitBuf.indexOf("\n");
			final idx = if (rIdx == -1) nIdx else if (nIdx == -1) rIdx else (rIdx < nIdx ? rIdx : nIdx);
			if (idx == -1)
				break;
			handleGitSegment(gitBuf.substring(0, idx));
			gitBuf = gitBuf.substring(idx + 1);
		}
	}

	static function handleGitSegment(seg:String) {
		if (!gitPhaseEReg.match(seg))
			return; // swallow info/error lines - errors resurface if the command fails
		final pct = Std.parseInt(gitPhaseEReg.matched(2));
		if (pct == null)
			return;
		final phase = gitPhaseEReg.matched(1);
		final label = switch phase {
			case "Receiving objects": "Receiving";
			case "Resolving deltas": "Resolving";
			case "Compressing objects": "Compressing";
			default: "Counting";
		}
		// for the download phase, show git's own "size | speed" detail
		var detail = '(${gitPhaseEReg.matched(3)}/${gitPhaseEReg.matched(4)})';
		if (phase == "Receiving objects") {
			final ci = seg.indexOf("), ");
			if (ci != -1)
				detail = StringTools.replace(seg.substring(ci + 3), ", done.", "");
		}
		final reserve = 44;
		var stats = '$label $pct%  $detail';
		if (stats.length > reserve)
			stats = stats.substr(0, reserve);
		final width = barWidthFor(reserve);
		drawBar(solidBar(pct / 100, width), width, StringTools.rpad(stats, " ", reserve), reserve, false);
	}

	public static function finishVcsProgress() {
		gitBuf = "";
		if (lastVisibleLen > 0) {
			Sys.print("\n");
			lastVisibleLen = 0;
		}
	}

	public static function getInput(prompt:String): String {
		Sys.print('$prompt : ');
		return Sys.stdin().readLine();
	}

	//
	// ── Tagged output ────────────────────────────────────────────────────────
	//
	// Every human facing line is prefixed with a coloured level tag ([INFO],
	// [WARN], [ERROR], [DEBUG]). Machine readable command output (path, libpath,
	// config) must stay clean - use `printRaw` for those, never `print`.
	//

	/** Builds a padded, coloured `[LABEL]` tag followed by `msg`. **/
	static function tagged(label:String, rgb:String, msg:String):String {
		final tag = paint(rgb, StringTools.rpad('[$label]', " ", 7));
		return '$tag $msg';
	}

	static inline function infoTag(msg:String):String
		return tagged("INFO", C_GRAY, msg); // dark grey

	static inline function warnTag(msg:String):String
		return tagged("WARN", C_YELLOW, msg); // amber

	static inline function errorTag(msg:String):String
		return tagged("ERROR", C_RED, msg); // red

	static inline function debugTag(msg:String):String
		return tagged("DEBUG", C_DIM, msg); // dim grey

	/** Human facing info line, tagged `[INFO]`. **/
	public static inline function print(str:String)
		Sys.println(infoTag(str));

	/** Raw, untagged line - for machine readable output the toolchain parses. **/
	public static inline function printRaw(str:String)
		Sys.println(str);

	/** Dimmed line with no tag (credits, subtle notes). **/
	public static inline function printDim(str:String)
		Sys.println(paint(C_DIM, str));

	public static inline function printString(str:String)
		Sys.print(str);

	public static inline function printWarning(message:String)
		if (mode != Quiet)
			Sys.stderr().writeString(warnTag(message) + "\n");

	public static inline function printError(message:String)
		Sys.stderr().writeString(errorTag(message) + "\n");

	/** Prints `message` to stdout only if in Debug mode **/
	public static function printDebug(message:String)
		if (mode == Debug)
			Sys.println(debugTag(message));

	/** Prints `message` to stderr only if in Debug mode **/
	public static function printDebugError(message:String)
		if (mode == Debug)
			Sys.stderr().writeString(debugTag(message) + "\n");

	/** Prints `message` to stdout, unless in Quiet mode **/
	public static function printOptional(message:String)
		if (mode != Quiet)
			Sys.println(infoTag(message));

	/** Prints `message` to stderr, unless in Quiet mode **/
	public static function printOptionalError(message:String)
		if (mode != Quiet)
			Sys.stderr().writeString(infoTag(message) + "\n");

}
