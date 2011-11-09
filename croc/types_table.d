/******************************************************************************
This module contains internal implementation of the table object.

License:
Copyright (c) 2008 Jarrett Billingsley

This software is provided 'as-is', without any express or implied warranty.
In no event will the authors be held liable for any damages arising from the
use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it freely,
subject to the following restrictions:

    1. The origin of this software must not be misrepresented; you must not
	claim that you wrote the original software. If you use this software in a
	product, an acknowledgment in the product documentation would be
	appreciated but is not required.

    2. Altered source versions must be plainly marked as such, and must not
	be misrepresented as being the original software.

    3. This notice may not be removed or altered from any source distribution.
******************************************************************************/

module croc.types_table;

import croc.base_alloc;
import croc.base_writebarrier;
import croc.base_hash;
import croc.types;

struct table
{
static:
	// ================================================================================================================================================
	// Package
	// ================================================================================================================================================

	// Create a new table object with `size` slots preallocated in it.
	package CrocTable* create(ref Allocator alloc, uword size = 0)
	{
		auto t = alloc.allocate!(CrocTable);
		t.data.prealloc(alloc, size);
		return t;
	}

	// Free a table object.
	package void free(ref Allocator alloc, CrocTable* t)
	{
		t.data.clear(alloc);
		alloc.free(t);
	}

	// Get a pointer to the value of a key-value pair, or null if it doesn't exist.
	package CrocValue* get(CrocTable* t, CrocValue key)
	{
		return t.data.lookup(key);
	}
	
	package void idxa(ref Allocator alloc, CrocTable* t, ref CrocValue key, ref CrocValue val)
	{
		auto node = t.data.lookupNode(key);

		if(node !is null)
		{
			if(val.type == CrocValue.Type.Null)
			{
				// Remove
				mixin(removeKeyRef!("alloc", "node"));
				mixin(removeValueRef!("alloc", "node"));
				t.data.remove(key);
			}
			else if(node.value != val)
			{
				// Update
				mixin(removeValueRef!("alloc", "node"));
				node.value = val;

				if(val.isObject())
				{
					mixin(containerWriteBarrier!("alloc", "t"));
					node.modified |= ValModified;
				}
				else
					node.modified &= ~ValModified;
			}
		}
		else if(val.type != CrocValue.Type.Null)
		{
			// Insert
			node = t.data.insertNode(alloc, key);
			node.value = val;

			if(key.isObject() || val.isObject())
			{
				mixin(containerWriteBarrier!("alloc", "t"));
				node.modified |= (key.isObject() ? KeyModified : 0) | (val.isObject() ? ValModified : 0);
			}
		}

		// otherwise, do nothing (val is null and key doesn't exist)
	}

	// remove all key-value pairs from the table.
	package void clear(ref Allocator alloc, CrocTable* t)
	{
		foreach(ref node; &t.data.allNodes)
		{
			mixin(removeKeyRef!("alloc", "node"));
			mixin(removeValueRef!("alloc", "node"));
		}

		t.data.clear(alloc);
	}

	// Returns `true` if the key exists in the table.
	package bool contains(CrocTable* t, ref CrocValue key)
	{
		return t.data.lookup(key) !is null;
	}

	// Get the number of key-value pairs in the table.
	package uword length(CrocTable* t)
	{
		return t.data.length();
	}

	package bool next(CrocTable* t, ref size_t idx, ref CrocValue* key, ref CrocValue* val)
	{
		return t.data.next(idx, key, val);
	}

	package template removeKeyRef(char[] alloc, char[] slot)
	{
		const char[] removeKeyRef =
		"if(!(" ~ slot  ~ ".modified & KeyModified) && " ~ slot  ~ ".key.isObject()) " ~ alloc ~ ".decBuffer.add(" ~ alloc ~ ", " ~ slot  ~ ".key.toGCObject());";
	}

	package template removeValueRef(char[] alloc, char[] slot)
	{
		const char[] removeValueRef =
		"if(!(" ~ slot  ~ ".modified & ValModified) && " ~ slot  ~ ".value.isObject()) " ~ alloc ~ ".decBuffer.add(" ~ alloc ~ ", " ~ slot  ~ ".value.toGCObject());";
	}
}