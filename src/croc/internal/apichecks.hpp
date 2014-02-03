#ifndef CROC_INTERNAL_APICHECKS_HPP
#define CROC_INTERNAL_APICHECKS_HPP

#define API_CHECK_NUM_PARAMS(numParams)\
	do {\
		assert(t->stackIndex > t->stackBase);\
		if((croc_getStackSize(*t) - 1) < (numParams))\
			assert(false);\
	} while(false)
			// TODO:ex
			// croc_eh_throwStd(*t, "ApiError",
			// 	__FUNCTION__ " - not enough parameters (expected {}, only have {} stack slots)",
			// 	(numParams),
			// 	croc_getStackSize(*t) - 1);

// template apiCheckParam(char[] newVar, char[] idx, char[] paramName, char[] expected, char[] t = "t")
// {
//
// }

#define API_PARAM_TYPE_ERROR(idx, paramName, expected)\
	do {\
		assert(false);\
	} while(false)
	// TODO:ex
	// croc_pushTypeString(*t, (idx));
	// croc_eh_throwStd(*t, "TypeError",
	// 	__FUNCTION__ " - Expected type '" expected "' for " paramName ", not '{}'", croc_getString(*t, -1));

#endif