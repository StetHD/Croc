
#include "croc/api.h"
#include "croc/internal/stack.hpp"
#include "croc/stdlib/helpers/oscompat.hpp"
#include "croc/stdlib/helpers/register.hpp"
#include "croc/types/base.hpp"

namespace croc
{
	namespace
	{
#include "croc/stdlib/console.croc.hpp"
	}

	void initConsoleLib(CrocThread* t)
	{
		croc_table_new(t, 0);
			auto in = oscompat::getStdin(t);
			if(in == oscompat::InvalidHandle)
				oscompat::throwIOEx(t);

			auto out = oscompat::getStdout(t);
			if(out == oscompat::InvalidHandle)
				oscompat::throwIOEx(t);

			auto err = oscompat::getStderr(t);
			if(err == oscompat::InvalidHandle)
				oscompat::throwIOEx(t);

			croc_pushNativeobj(t, cast(void*)cast(uword)in);  croc_fielda(t, -2, "stdin");
			croc_pushNativeobj(t, cast(void*)cast(uword)out); croc_fielda(t, -2, "stdout");
			croc_pushNativeobj(t, cast(void*)cast(uword)err); croc_fielda(t, -2, "stderr");
		croc_newGlobal(t, "_consoletmp");

		registerModuleFromString(t, "console", console_croc_text, "console.croc");

		croc_vm_pushGlobals(t);
		croc_pushString(t, "_consoletmp");
		croc_removeKey(t, -2);
		croc_popTop(t);
	}
}