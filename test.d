module test;

import tango.core.tools.TraceExceptions;
import tango.io.Stdout;

import minid.api;

// import minid.addons.pcre;
// import minid.addons.sdl;
// import minid.addons.gl;
// import minid.addons.net;

/*
Language changes:
- Trailing commas now allowed in table and array constructors
- Labeled control structures, breaks, and continues
*/

void main()
{
	scope(exit) Stdout.flush;

	MDVM vm;
	auto t = openVM(&vm);
	loadStdlibs(t, MDStdlib.ReallyAll);

	try
	{
// 		PcreLib.init(t);
// 		SdlLib.init(t);
// 		GlLib.init(t);
// 		NetLib.init(t);

		importModule(t, "samples.simple");
		pushNull(t);
		lookup(t, "modules.runMain");
		swap(t, -3);
		rawCall(t, -3, 0);
	}
	catch(MDException e)
	{
		catchException(t);
		Stdout.formatln("Error: {}", e);

		getTraceback(t);
		Stdout.formatln("{}", getString(t, -1));

		pop(t, 2);

		if(e.info)
		{
			Stdout("D Traceback:");
			e.writeOut((char[]s) { Stdout(s); });
		}
	}
	catch(MDHaltException e)
		Stdout.formatln("Thread halted");
	catch(Exception e)
	{
		Stdout("Bad error:").newline;
		e.writeOut((char[]s) { Stdout(s); });
		return;
	}

	closeVM(&vm);
}