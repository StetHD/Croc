
#include "croc/types.hpp"
#include "croc/types/string.hpp"
#include "croc/utf.hpp"
#include "croc/utils.hpp"

#define STRING_EXTRA_SIZE(len) (sizeof(char) * (len))

namespace croc
{
	namespace string
	{
		String* lookup(VM* vm, crocstr data, uword& h)
		{
			// We don't have to verify the string if it already exists in the string table,
			// because if it does, it means it's a legal string.
			// Neither hashing nor lookup require the string to be valid UTF-8.
			h = data.toHash();

			auto s = vm->stringTab.lookup(data, h);

			if(s)
				return *s;

			return nullptr;
		}

		// Create a new string object. String objects with the same data are reused. Thus,
		// if two string objects are identical, they are also equal.
		String* create(VM* vm, crocstr data, uword h, uword cpLen)
		{
			auto ret = ALLOC_OBJSZ_ACYC(vm->mem, String, STRING_EXTRA_SIZE(data.length));
			ret->hash = h;
			ret->length = data.length;
			ret->cpLength = cpLen;
			ret->setData(data);

			*vm->stringTab.insert(vm->mem, ret->toDArray()) = ret;
			return ret;
		}

		// Free a string object.
		void free(VM* vm, String* s)
		{
			bool b = vm->stringTab.remove(s->toDArray());
			assert(b);
			FREE_OBJ(vm->mem, String, s);
		}

		// Compare two string objects.
		crocint compare(String* a, String* b)
		{
			return scmp(a->toDArray(), b->toDArray());
		}

		// See if the string contains the given substring.
		bool contains(String* s, crocstr sub)
		{
			if(s->length < sub.length)
				return false;

			// TODO:
			// return s.toString().locatePattern(sub) != s.length;
			return false;
		}

		// The slice indices are in codepoints, not byte indices.
		// And these indices better be good.
		String* slice(VM* vm, String* s, uword lo, uword hi)
		{
			auto str = utf8Slice(s->toDArray(), lo, hi);
			uword h;

			if(auto s = lookup(vm, str, h))
				return s;

			// don't have to verify since we're slicing from a string we know is good
			return create(vm, str, h, hi - lo);
		}

		// Like slice, the index is in codepoints, not byte indices.
		dchar charAt(String* s, uword idx)
		{
			return utf8CharAt(s->toDArray(), idx);
		}
	}
}