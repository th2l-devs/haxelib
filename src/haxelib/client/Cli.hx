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
	// drawn in colour. Colours can be turned off by setting the `NO_COLOR`
	// environment variable; the box-drawing glyph falls back to ASCII when
	// `HAXELIB_NO_UNICODE` is set (for consoles that are not UTF-8).
	//

	static final ESC = "\x1b";

	/** Whether ANSI colours are emitted. Honours the `NO_COLOR` convention. **/
	static final useColor:Bool = Sys.getEnv("NO_COLOR") == null;

	/** Whether the fancy box-drawing bar glyph is used (vs. an ASCII fallback). **/
	static final useUnicode:Bool = Sys.getEnv("HAXELIB_NO_UNICODE") == null;

	static final BAR_FILL = useUnicode ? "━" : "=";
	static final BAR_TRACK = useUnicode ? "━" : "-";

	/** Frame counter used to animate the pulse shown when the total is unknown. **/
	static var pulseFrame = 0;

	/** Length (in visible columns) of the last status line, to blank leftovers. **/
	static var lastVisibleLen = 0;

	static var cachedWidth = 0;

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

	static inline function paint(rgb:String, s:String):String
		return useColor ? '$ESC[38;2;${rgb}m$s$ESC[0m' : s;

	/** Repeats `s` `n` times (safe for multi-byte glyphs). **/
	static function repeatStr(s:String, n:Int):String {
		final buf = new StringBuf();
		for (_ in 0...n)
			buf.add(s);
		return buf.toString();
	}

	/**
		Best-effort detection of the terminal width, cached for the session.

		Falls back to 80 columns if the width cannot be determined.
	**/
	static function terminalWidth():Int {
		if (cachedWidth != 0)
			return cachedWidth;
		cachedWidth = 80;
		inline function accept(n:Null<Int>):Bool {
			if (n != null && n >= 20) {
				cachedWidth = n > 200 ? 200 : n;
				return true;
			}
			return false;
		}
		if (accept(Std.parseInt(Sys.getEnv("COLUMNS") ?? "")))
			return cachedWidth;
		try {
			if (Sys.systemName() == "Windows") {
				final p = new sys.io.Process("powershell", ["-NoProfile", "-Command", "[Console]::WindowWidth"]);
				final out = p.stdout.readAll().toString();
				p.close();
				accept(Std.parseInt(StringTools.trim(out)));
			} else {
				final p = new sys.io.Process("stty", ["size"]);
				final out = p.stdout.readAll().toString();
				p.close();
				final parts = StringTools.trim(out).split(" ");
				if (parts.length == 2)
					accept(Std.parseInt(parts[1]));
			}
		} catch (_:Dynamic) {}
		return cachedWidth;
	}

	/** Renders a solid `━` bar of `width` columns filled to `fraction` (0-1). **/
	static function solidBar(fraction:Float, width:Int):String {
		if (fraction < 0) fraction = 0;
		if (fraction > 1) fraction = 1;
		final filled = Math.round(fraction * width);
		// filled part in pink, remaining track in dim grey, matching pip
		return paint("249;38;114", repeatStr(BAR_FILL, filled))
			+ paint("88;91;112", repeatStr(BAR_TRACK, width - filled));
	}

	/** Renders an indeterminate "pulse" bar with a block sweeping across it. **/
	static function pulseBar(width:Int):String {
		final seg = Std.int(width / 4);
		final pos = pulseFrame++ % (width + seg) - seg;
		final buf = new StringBuf();
		for (i in 0...width)
			buf.add(paint(i >= pos && i < pos + seg ? "249;38;114" : "88;91;112", BAR_FILL));
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

	static inline function barWidthFor(reserve:Int):Int {
		final w = terminalWidth() - 4 - reserve;
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

	public static function getInput(prompt:String): String {
		Sys.print('$prompt : ');
		return Sys.stdin().readLine();
	}

	public static inline function print(str:String)
		Sys.println(str);

	public static inline function printString(str:String)
		Sys.print(str);

	public static inline function printWarning(message:String)
		if (mode != Quiet)
			Sys.stderr().writeString('Warning: $message\n');

	public static inline function printError(message:String)
		Sys.stderr().writeString('${message}\n');

	/** Prints `message` to stdout only if in Debug mode **/
	public static function printDebug(message:String)
		if (mode == Debug)
			Sys.println(message);

	/** Prints `message` to stderr only if in Debug mode **/
	public static function printDebugError(message:String)
		if (mode == Debug)
			Sys.stderr().writeString('${message}\n');

	/** Prints `message` to stdout, unless in Quiet mode **/
	public static function printOptional(message:String)
		if (mode != Quiet)
			Sys.println(message);

	/** Prints `message` to stderr, unless in Quiet mode **/
	public static function printOptionalError(message:String)
		if (mode != Quiet)
			Sys.stderr().writeString('${message}\n');

}
