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

	/** Width (in characters) of the drawn progress bars. **/
	static inline final BAR_WIDTH = 30;

	/** Frame counter used to animate the spinner shown for unknown totals. **/
	static var spinnerFrame = 0;

	static final SPINNER_CHARS = ["|", "/", "-", "\\"];

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

	/** Formats a duration in seconds as `m:ss`, e.g. `0:07` or `2:41`. **/
	static function formatTime(seconds:Float):String {
		var total = Std.int(seconds);
		if (total < 0)
			total = 0;
		final mins = Std.int(total / 60);
		final secs = total % 60;
		return '$mins:' + (secs < 10 ? '0$secs' : '$secs');
	}

	/** Renders a `[#########---------]` style bar filled to `fraction` (0-1). **/
	static function progressBar(fraction:Float):String {
		if (fraction < 0) fraction = 0;
		if (fraction > 1) fraction = 1;
		final filled = Math.round(fraction * BAR_WIDTH);
		final buf = new StringBuf();
		buf.addChar("[".code);
		for (i in 0...BAR_WIDTH)
			buf.addChar(if (i < filled) "#".code else "-".code);
		buf.addChar("]".code);
		return buf.toString();
	}

	/** Returns the next frame of the spinner used when the total is unknown. **/
	static function spinner():String {
		return SPINNER_CHARS[spinnerFrame++ % SPINNER_CHARS.length];
	}

	/** Length of the last status line drawn, used to blank out leftovers. **/
	static var lastStatusLength = 0;

	/**
		Redraws the current console line with `line`.

		Uses `\r` + space padding rather than ANSI escape codes, so it works
		on consoles without VT support (e.g. legacy Windows conhost).
	**/
	static function reprintLine(line:String) {
		Sys.print("\r" + StringTools.rpad(line, " ", lastStatusLength));
		lastStatusLength = line.length;
	}

	/** Like `reprintLine`, but terminates the line: further output starts fresh. **/
	static function finishLine(line:String) {
		Sys.println("\r" + StringTools.rpad(line, " ", lastStatusLength));
		lastStatusLength = 0;
	}

	public static function printInstallStatus(_, current:Int, total:Int) {
		if (current != total) {
			final fraction = current / total;
			final percent = Std.int(fraction * 100);
			reprintLine('  ${progressBar(fraction)} $percent% (${current + 1}/$total files)');
		} else {
			// clear the bar
			reprintLine("");
			Sys.print("\r");
		}
	}

	public static function printUploadStatus(pos:Int, total:Int) {
		final fraction = pos / total;
		reprintLine('  ${progressBar(fraction)} ${Std.int(fraction * 100)}% ${formatBytesPair(pos, total)}');
	}

	public static function printDownloadStatus(label:String, finished:Bool, cur:Int, max:Null<Int>, downloaded:Int, time:Float) {
		final speed = time > 0 ? downloaded / time : 0;
		final speedStr = formatBytes(Std.int(speed)) + "/s";

		if (finished) {
			finishLine('$label: ${formatBytes(downloaded)} in ${formatTime(time)} ($speedStr)');
		} else if (max == null) {
			// total size unknown: spinner + running byte count so it visibly moves
			reprintLine('$label ${spinner()} ${formatBytes(cur)} $speedStr ${formatTime(time)}');
		} else {
			final fraction = cur / max;
			final percent = Std.int(fraction * 100);
			final etaStr = speed > 0 ? formatTime((max - cur) / speed) : "-:--";
			reprintLine('$label ${progressBar(fraction)} $percent% ${formatBytesPair(cur, max)} $speedStr eta $etaStr');
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
