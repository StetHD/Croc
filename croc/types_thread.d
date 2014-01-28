/******************************************************************************
This module contains internal implementation of the thread object.

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

module croc.types_thread;

version(CrocExtendedThreads)
	import tango.core.Thread;

import croc.base_alloc;
import croc.base_writebarrier;
import croc.types;
import croc.types_nativeobj;

struct thread
{
static:
	// ================================================================================================================================================
	// Package
	// ================================================================================================================================================

package:

	// Create a new thread object.
	CrocThread* create(CrocVM* vm)
	{
		auto t = createPartial(vm);
		auto alloc = &vm.alloc;

		t.tryRecs = alloc.allocArray!(TryRecord)(10);
		t.actRecs = alloc.allocArray!(ActRecord)(10);
		t.stack = alloc.allocArray!(CrocValue)(20);
		t.results = alloc.allocArray!(CrocValue)(8);

		t.stackIndex = cast(AbsStack)1; // So that there is a 'this' at top-level.

		return t;
	}

	// Partially create a new thread. Doesn't allocate any memory for its various stacks. Used for serialization.
	CrocThread* createPartial(CrocVM* vm)
	{
		auto t = vm.alloc.allocate!(CrocThread);
		t.vm = vm;
		t.next = vm.allThreads;

		if(t.next)
			t.next.prev = t;

		vm.allThreads = t;
		return t;
	}

	// Create a new thread object with a function to be used as the coroutine body.
	CrocThread* create(CrocVM* vm, CrocFunction* coroFunc)
	{
		auto t = create(vm);
		t.coroFunc = coroFunc;

		version(CrocExtendedThreads)
		{
			version(CrocPoolFibers)
			{
				if(vm.fiberPool.length > 0)
				{
					Fiber f = void;

					foreach(fiber, _; vm.fiberPool)
					{
						f = fiber;
						break;
					}

					vm.fiberPool.remove(f);
					t.threadFiber = nativeobj.create(vm, f);
				}
			}
		}

		return t;
	}

	void reset(CrocThread* t)
	{
		assert(t.upvalHead is null); // should be..?

		version(CrocExtendedThreads)
		{
			if(t.threadFiber)
			{
				assert(t.getFiber().state == Fiber.State.TERM);
				t.getFiber().reset();
			}
		}

		t.currentTR = null;
		t.trIndex = 0;
		t.currentAR = null;
		t.arIndex = 0;
		t.stackIndex = cast(AbsStack)1;
		t.stackBase = cast(AbsStack)0;
		t.resultIndex = 0;
		t.shouldHalt = false;
		t.state = CrocThread.State.Initial;
	}

	void setHookFunc(ref Allocator alloc, CrocThread* t, CrocFunction* f)
	{
		if(t.hookFunc !is f)
		{
			mixin(writeBarrier!("alloc", "t"));
			t.hookFunc = f;
		}
	}

	void setCoroFunc(ref Allocator alloc, CrocThread* t, CrocFunction* f)
	{
		if(t.coroFunc !is f)
		{
			mixin(writeBarrier!("alloc", "t"));
			t.coroFunc = f;
		}
	}

	version(CrocExtendedThreads)
	{
		void setThreadFiber(ref Allocator alloc, CrocThread* t, CrocNativeObj* f)
		{
			if(t.threadFiber !is f)
			{
				mixin(writeBarrier!("alloc", "t"));
				t.threadFiber = f;
			}
		}
	}

	// Free a thread object.
	void free(CrocThread* t)
	{
		if(t.next) t.next.prev = t.prev;
		if(t.prev) t.prev.next = t.next;

		if(t.vm.allThreads is t)
			t.vm.allThreads = t.next;

		version(CrocExtendedThreads)
		{
			version(CrocPoolFibers)
			{
				if(t.threadFiber)
					t.vm.fiberPool[t.getFiber()] = true;
			}
		}

		for(auto uv = t.upvalHead; uv !is null; uv = t.upvalHead)
		{
			t.upvalHead = uv.nextuv;
			uv.closedValue = *uv.value;
			uv.value = &uv.closedValue;
		}

		auto alloc = &t.vm.alloc;

		alloc.freeArray(t.results);
		alloc.freeArray(t.stack);
		alloc.freeArray(t.actRecs);
		alloc.freeArray(t.tryRecs);
		alloc.free(t);
	}
}