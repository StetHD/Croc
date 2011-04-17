/******************************************************************************
This module contains functions for serializing and deserializing compiled MiniD
functions and modules.

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

module minid.serialization;

import tango.core.BitManip;
import tango.core.Exception;
import tango.io.model.IConduit;


import minid.ex;


import minid.hash;
import minid.interpreter;
import minid.stackmanip;
import minid.types;
import minid.types_function;
import minid.types_instance;

// ================================================================================================================================================
// Public
// ================================================================================================================================================

public:

void serializeGraph(MDThread* t, word idx, word trans, OutputStream output)
{
	auto s = Serializer(t, output);
	s.writeGraph(idx, trans);
}

word deserializeGraph(MDThread* t, word trans, InputStream input)
{
	auto d = Deserializer(t, input);
	return d.readGraph(trans);
}

// ================================================================================================================================================
// Private
// ================================================================================================================================================

private:

struct Serializer
{
private:
	MDThread* t;
	OutputStream mOutput;
	Hash!(MDBaseObject*, uword) mObjTable;
	uword mObjIndex;
	MDTable* mTrans;
	MDInstance* mStream;
	MDFunction* mSerializeFunc;

	enum
	{
		Backref = -1,
		Transient = -2
	}

	static Serializer opCall(MDThread* t, OutputStream output)
	{
		Serializer ret;
		ret.t = t;
		ret.mOutput = output;
		return ret;
	}

	static class Goober
	{
		Serializer* s;
		this(Serializer* s) { this.s = s; }
	}

	static uword serializeFunc(MDThread* t)
	{
		if(!isValidIndex(t, 1))
			throwException(t, "Expected at least one parameter");

		getUpval(t, 0);
		auto g = cast(Goober)getNativeObj(t, -1);
		g.s.serialize(*getValue(t, 1));
		return 0;
	}

	void writeGraph(word value, word trans)
	{
		if(opis(t, value, trans))
			throwException(t, "Object to serialize is the same as the transients table");

		if(!isTable(t, trans))
		{
			pushTypeString(t, trans);
			throwException(t, "Transients table must be a table, not '{}'", getString(t, -1));
		}

		mTrans = getTable(t, trans);
		auto v = *getValue(t, value);

		auto size = stackSize(t);

		mObjTable.clear(t.vm.alloc);
		mObjIndex = 0;

		scope(exit)
		{
			setStackSize(t, size);
			mObjTable.clear(t.vm.alloc);
		}

		// we leave these on the stack so they won't be collected, but we get 'real' references
		// to them so we can push them in opSerialize callbacks.
		importModuleNoNS(t, "stream");
		lookup(t, "stream.OutStream");
		pushNull(t);
		pushNativeObj(t, cast(Object)mOutput);
		pushBool(t, false);
		rawCall(t, -4, 1);
		mStream = getInstance(t, -1);

			pushNativeObj(t, new Goober(this));
		newFunction(t, 1, &serializeFunc, "serialize", 1);
		mSerializeFunc = getFunction(t, -1);

		serialize(v);

		mOutput.flush();
	}

	void tag(byte v)
	{
		put(mOutput, v);
	}

	void integer(long v)
	{
		if(v == 0)
		{
			put!(byte)(mOutput, 0);
			return;
		}
		else if(v == long.min)
		{
			// this is special-cased since -long.min == long.min!
			put(mOutput, cast(byte)0xFF);
			return;
		}

		int numBytes = void;
		bool neg = v < 0;

		if(neg)
			v = -v;

		if(v & 0xFFFF_FFFF_0000_0000)
			numBytes = (bsr(cast(uint)(v >>> 32)) / 8) + 5;
		else
			numBytes = (bsr(cast(uint)v) / 8) + 1;

		put(mOutput, cast(ubyte)(neg ? numBytes | 0x80 : numBytes));

		while(v)
		{
			put(mOutput, cast(ubyte)(v & 0xFF));
			v >>>= 8;
		}
	}

	void serialize(MDValue v)
	{
		// check to see if it's an transient value
		push(t, MDValue(mTrans));
		push(t, v);
		idx(t, -2);

		if(!isNull(t, -1))
		{
			tag(Transient);
			serialize(*getValue(t, -1));
			pop(t, 2);
			return;
		}

		pop(t, 2);

		// serialize it
		switch(v.type)
		{
			case MDValue.Type.Null:      serializeNull();                  break;
			case MDValue.Type.Bool:      serializeBool(v.mBool);           break;
			case MDValue.Type.Int:       serializeInt(v.mInt);             break;
			case MDValue.Type.Float:     serializeFloat(v.mFloat);         break;
			case MDValue.Type.Char:      serializeChar(v.mChar);           break;
			case MDValue.Type.String:    serializeString(v.mString);       break;
			case MDValue.Type.Table:     serializeTable(v.mTable);         break;
			case MDValue.Type.Array:     serializeArray(v.mArray);         break;
			case MDValue.Type.Function:  serializeFunction(v.mFunction);   break;
			case MDValue.Type.Class:     serializeClass(v.mClass);         break;
			case MDValue.Type.Instance:  serializeInstance(v.mInstance);   break;
			case MDValue.Type.Namespace: serializeNamespace(v.mNamespace); break;
			case MDValue.Type.Thread:    serializeThread(v.mThread);       break;
			case MDValue.Type.WeakRef:   serializeWeakRef(v.mWeakRef);     break;
			case MDValue.Type.NativeObj: serializeNativeObj(v.mNativeObj); break;
			case MDValue.Type.FuncDef:   serializeFuncDef(v.mFuncDef);     break;

			case MDValue.Type.Upvalue:   serializeUpval(cast(MDUpval*)v.mBaseObj);         break;

			default: assert(false);
		}
	}

	void serializeNull()
	{
		tag(MDValue.Type.Null);
	}

	void serializeBool(bool v)
	{
		tag(MDValue.Type.Bool);
		put(mOutput, v);
	}

	void serializeInt(mdint v)
	{
		tag(MDValue.Type.Int);
		integer(v);
	}

	void serializeFloat(mdfloat v)
	{
		tag(MDValue.Type.Float);
		put(mOutput, v);
	}

	void serializeChar(dchar v)
	{
		tag(MDValue.Type.Char);
		integer(v);
	}

	void serializeString(MDString* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.String);
		auto data = v.toString();
		integer(data.length);
		append(mOutput, data);
	}

	void serializeTable(MDTable* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Table);
		integer(v.data.length);

		foreach(ref key, ref val; v.data)
		{
			serialize(key);
			serialize(val);
		}
	}

	void serializeArray(MDArray* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Array);
		integer(v.length);

		foreach(ref val; v.toArray())
			serialize(val);
	}

	void serializeFunction(MDFunction* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Function);

		if(v.isNative)
		{
			push(t, MDValue(v));
			throwException(t, "Attempting to persist a native function '{}'", funcName(t, -1));
		}

		// we do this first so we can allocate it at the beginning of deserialization
		integer(v.numUpvals);

		serialize(MDValue(v.name));
		serialize(MDValue(cast(MDBaseObject*)v.scriptFunc));

		if(v.environment is t.vm.globals)
			put(mOutput, false);
		else
		{
			put(mOutput, true);
			serialize(MDValue(v.environment));
		}

		foreach(val; v.scriptUpvals)
			serialize(MDValue(cast(MDBaseObject*)val));
	}

	void serializeUpval(MDUpval* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Upvalue);
		serialize(*v.value);
	}

	void serializeFuncDef(MDFuncDef* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.FuncDef);
		serialize(MDValue(v.location.file));
		integer(v.location.line);
		integer(v.location.col);
		put(mOutput, v.isVararg);
		serialize(MDValue(v.name));
		integer(v.numParams);
		integer(v.paramMasks.length);

		foreach(mask; v.paramMasks)
			integer(mask);

		integer(v.numUpvals);
		integer(v.stackSize);
		integer(v.innerFuncs.length);

		foreach(func; v.innerFuncs)
			serialize(MDValue(cast(MDBaseObject*)func));

		integer(v.constants.length);

		foreach(ref val; v.constants)
			serialize(val);

		integer(v.code.length);
		append(mOutput, v.code);

		if(auto e = v.environment)
		{
			put(mOutput, true);
			serialize(MDValue(e));
		}
		else
			put(mOutput, false);

		if(auto f = v.cachedFunc)
		{
			put(mOutput, true);
			serialize(MDValue(f));
		}
		else
			put(mOutput, false);

		integer(v.switchTables.length);

		foreach(ref st; v.switchTables)
		{
			integer(st.offsets.length);

			foreach(ref k, v; st.offsets)
			{
				serialize(k);
				integer(v);
			}

			integer(st.defaultOffset);
		}

		integer(v.lineInfo.length);
		append(mOutput, v.lineInfo);
		integer(v.upvalNames.length);

		foreach(name; v.upvalNames)
			serialize(MDValue(name));

		integer(v.locVarDescs.length);

		foreach(ref desc; v.locVarDescs)
		{
			serialize(MDValue(desc.name));
			integer(desc.pcStart);
			integer(desc.pcEnd);
			integer(desc.reg);
		}
	}

	void serializeClass(MDClass* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		if(v.allocator || v.finalizer)
		{
			push(t, MDValue(v));
			pushToString(t, -1);
			throwException(t, "Attempting to serialize '{}', which has an allocator or finalizer", getString(t, -1));
		}

		tag(MDValue.Type.Class);
		serialize(MDValue(v.name));

		if(v.parent)
		{
			put(mOutput, true);
			serialize(MDValue(v.parent));
		}
		else
			put(mOutput, false);

		assert(v.fields !is null);
		serialize(MDValue(v.fields));
	}

	void serializeInstance(MDInstance* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Instance);
		integer(v.numValues);
		integer(v.extraBytes);
		serialize(MDValue(v.parent));

		push(t, MDValue(v));

		if(hasField(t, -1, "opSerialize"))
		{
			field(t, -1, "opSerialize");

			if(isFunction(t, -1))
			{
				put(mOutput, true);
				pop(t);
				pushNull(t);
				push(t, MDValue(mStream));
				push(t, MDValue(mSerializeFunc));
				methodCall(t, -4, "opSerialize", 0);
				return;
			}
			else if(isBool(t, -1))
			{
				if(!getBool(t, -1))
				{
					pushToString(t, -2, true);
					throwException(t, "Attempting to serialize '{}', whose opSerialize field is 'false'", getString(t, -1));
				}

				pop(t);
				// fall out, serialize literally.
			}
			else
			{
				pushToString(t, -2, true);
				pushTypeString(t, -2);
				throwException(t, "Attempting to serialize '{}', whose opSerialize is a '{}', not a bool or function", getString(t, -2), getString(t, -1));
			}
		}

		pop(t);
		put(mOutput, false);

		if(v.numValues || v.extraBytes)
		{
			push(t, MDValue(v));
			pushToString(t, -1, true);
			throwException(t, "Attempting to serialize '{}', which has extra values or extra bytes", getString(t, -1));
		}

		if(v.parent.allocator || v.parent.finalizer)
		{
			push(t, MDValue(v));
			pushToString(t, -1, true);
			throwException(t, "Attempting to serialize '{}', whose class has an allocator or finalizer", getString(t, -1));
		}

		if(v.fields)
		{
			put(mOutput, true);
			serialize(MDValue(v.fields));
		}
		else
			put(mOutput, false);
	}

	void serializeNamespace(MDNamespace* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.Namespace);
		serialize(MDValue(v.name));

		if(v.parent is null)
			put(mOutput, false);
		else
		{
			put(mOutput, true);
			serialize(MDValue(v.parent));
		}

		integer(v.data.length);

		foreach(key, ref val; v.data)
		{
			serialize(MDValue(key));
			serialize(val);
		}
	}

	void serializeThread(MDThread* v)
	{
    	if(alreadyWritten(cast(MDBaseObject*)v))
    		return;

    	if(t is v)
    		throwException(t, "Attempting to serialize the currently-executing thread");

    	if(v.nativeCallDepth > 0)
    		throwException(t, "Attempting to serialize a thread with at least one native or metamethod call on its call stack");

		tag(MDValue.Type.Thread);

		version(MDExtendedCoro)
		{
			put(mOutput, true);
		}
		else
		{
			put(mOutput, false);
			integer(v.savedCallDepth);
		}

		integer(v.arIndex);

		foreach(ref rec; v.actRecs[0 .. v.arIndex])
		{
			integer(rec.base);
			integer(rec.savedTop);
			integer(rec.vargBase);
			integer(rec.returnSlot);

			if(rec.func is null)
				put(mOutput, false);
			else
			{
				put(mOutput, true);
				serialize(MDValue(rec.func));
				uword diff = rec.pc - rec.func.scriptFunc.code.ptr;
				integer(diff);
			}

			integer(rec.numReturns);

			if(rec.proto)
			{
				put(mOutput, true);
				serialize(MDValue(rec.proto));
			}
			else
				put(mOutput, false);

			integer(rec.numTailcalls);
			integer(rec.firstResult);
			integer(rec.numResults);
			integer(rec.unwindCounter);

			if(rec.unwindReturn)
			{
				put(mOutput, true);
				uword diff = rec.unwindReturn - rec.func.scriptFunc.code.ptr;
				integer(diff);
			}
			else
				put(mOutput, false);
		}

		integer(v.trIndex);

		foreach(ref rec; v.tryRecs[0 .. v.trIndex])
		{
			put(mOutput, rec.isCatch);
			integer(rec.slot);
			integer(rec.actRecord);

			uword diff = rec.pc - v.actRecs[rec.actRecord].func.scriptFunc.code.ptr;
			integer(diff);
		}

		integer(v.stackIndex);
		uword stackTop;

		if(v.arIndex > 0)
			stackTop = v.currentAR.savedTop;
		else
			stackTop = v.stackIndex;

		integer(stackTop);

		foreach(ref val; v.stack[0 .. stackTop])
			serialize(val);

		integer(v.stackBase);
		integer(v.resultIndex);

		foreach(ref val; v.results[0 .. v.resultIndex])
			serialize(val);

		put(mOutput, v.shouldHalt);

		if(v.coroFunc)
		{
			put(mOutput, true);
			serialize(MDValue(v.coroFunc));
		}
		else
			put(mOutput, false);

		integer(v.state);
		integer(v.numYields);

		// TODO: hooks?!

		for(auto uv = t.upvalHead; uv !is null; uv = uv.nextuv)
		{
			assert(uv.value !is &uv.closedValue);
			serialize(MDValue(cast(MDBaseObject*)uv));
			uword diff = uv.value - v.stack.ptr;
			integer(diff);
		}

		tag(MDValue.Type.Null);
	}

	void serializeWeakRef(MDWeakRef* v)
	{
		if(alreadyWritten(cast(MDBaseObject*)v))
			return;

		tag(MDValue.Type.WeakRef);

		if(v.obj is null)
			put(mOutput, true);
		else
		{
			put(mOutput, false);
			serialize(MDValue(v.obj));
		}
	}

	void serializeNativeObj(MDNativeObj* v)
	{
		throwException(t, "Attempting to serialize a nativeobj.  Please use the transients table.");
	}

	void writeRef(uword idx)
	{
		tag(Backref);
		integer(idx);
	}

	void addObject(MDBaseObject* v)
	{
		*mObjTable.insert(t.vm.alloc, v) = mObjIndex++;
	}

	bool alreadyWritten(MDValue v)
	{
		return alreadyWritten(v.mBaseObj);
	}

	bool alreadyWritten(MDBaseObject* v)
	{
		if(auto idx = mObjTable.lookup(v))
		{
			writeRef(*idx);
			return true;
		}

		addObject(v);
		return false;
	}
}

struct Deserializer
{
private:
	MDThread* t;
	InputStream mInput;
	MDBaseObject*[] mObjTable;
	MDTable* mTrans;
	MDInstance* mStream;
	MDFunction* mDeserializeFunc;

	static Deserializer opCall(MDThread* t, InputStream input)
	{
		Deserializer ret;
		ret.t = t;
		ret.mInput = input;
		return ret;
	}

	static class Goober
	{
		Deserializer* d;
		this(Deserializer* d) { this.d = d; }
	}

	static uword deserializeFunc(MDThread* t)
	{
		getUpval(t, 0);
		auto g = cast(Goober)getNativeObj(t, -1);
		g.d.deserializeValue();
		return 1;
	}

	word readGraph(word trans)
	{
		if(!isTable(t, trans))
		{
			pushTypeString(t, trans);
			throwException(t, "Transients table must be a table, not '{}'", getString(t, -1));
		}

		mTrans = getTable(t, trans);

		auto size = stackSize(t);
		t.vm.alloc.resizeArray(mObjTable, 0);
		auto oldLimit = t.vm.alloc.gcLimit;
		t.vm.alloc.gcLimit = typeof(oldLimit).max;

		scope(failure)
			setStackSize(t, size);

		scope(exit)
		{
			t.vm.alloc.resizeArray(mObjTable, 0);
			t.vm.alloc.gcLimit = oldLimit;
		}

		// we leave these on the stack so they won't be collected, but we get 'real' references
		// to them so we can push them in opSerialize callbacks.
		importModuleNoNS(t, "stream");
		lookup(t, "stream.InStream");
		pushNull(t);
		pushNativeObj(t, cast(Object)mInput);
		pushBool(t, false);
		rawCall(t, -4, 1);
		mStream = getInstance(t, -1);

			pushNativeObj(t, new Goober(this));
		newFunction(t, 0, &deserializeFunc, "deserialize", 1);
		mDeserializeFunc = getFunction(t, -1);

		deserializeValue();
		insertAndPop(t, -3);
		maybeGC(t);

		return stackSize(t) - 1;
	}

	byte tag()
	{
		byte ret = void;
		get(mInput, ret);
		return ret;
	}

	long integer()()
	{
		byte v = void;
		get(mInput, v);

		if(v == 0)
			return 0;
		else if(v == 0xFF)
			return long.min;
		else
		{
			bool neg = (v & 0x80) != 0;

			if(neg)
				v &= ~0x80;

			auto numBytes = v;
			long ret = 0;

			for(int shift = 0; numBytes; numBytes--, shift += 8)
			{
				get(mInput, v);
				ret |= v << shift;
			}

			return neg ? -ret : ret;
		}
	}

	void integer(T)(ref T x)
	{
		x = cast(T)integer();
	}

	void deserializeValue()
	{
		switch(tag())
		{
			case MDValue.Type.Null:      deserializeNullImpl();      break;
			case MDValue.Type.Bool:      deserializeBoolImpl();      break;
			case MDValue.Type.Int:       deserializeIntImpl();       break;
			case MDValue.Type.Float:     deserializeFloatImpl();     break;
			case MDValue.Type.Char:      deserializeCharImpl();      break;
			case MDValue.Type.String:    deserializeStringImpl();    break;
			case MDValue.Type.Table:     deserializeTableImpl();     break;
			case MDValue.Type.Array:     deserializeArrayImpl();     break;
			case MDValue.Type.Function:  deserializeFunctionImpl();  break;
			case MDValue.Type.Class:     deserializeClassImpl();     break;
			case MDValue.Type.Instance:  deserializeInstanceImpl();  break;
			case MDValue.Type.Namespace: deserializeNamespaceImpl(); break;
			case MDValue.Type.Thread:    deserializeThreadImpl();    break;
			case MDValue.Type.WeakRef:   deserializeWeakrefImpl();   break;
			case MDValue.Type.FuncDef:   deserializeFuncDefImpl();   break;
			case MDValue.Type.Upvalue:   deserializeUpvalImpl();     break;

			case Serializer.Backref:     push(t, MDValue(mObjTable[cast(uword)integer()])); break;

			case Serializer.Transient:
				push(t, MDValue(mTrans));
				deserializeValue();
				idx(t, -2);
				insertAndPop(t, -2);
				break;

			default: throwException(t, "Malformed data");
		}
	}

	void checkTag(byte type)
	{
		if(tag() != type)
			throwException(t, "Malformed data");
	}

	void deserializeNull()
	{
		checkTag(MDValue.Type.Null);
		deserializeNullImpl();
	}

	void deserializeNullImpl()
	{
		pushNull(t);
	}

	void deserializeBool()
	{
		checkTag(MDValue.Type.Bool);
		deserializeBoolImpl();
	}

	void deserializeBoolImpl()
	{
		bool v = void;
		get(mInput, v);
		pushBool(t, v);
	}
	
	void deserializeInt()
	{
		checkTag(MDValue.Type.Int);
		deserializeIntImpl();
	}

	void deserializeIntImpl()
	{
		pushInt(t, integer());
	}
	
	void deserializeFloat()
	{
		checkTag(MDValue.Type.Float);
		deserializeFloatImpl();
	}

	void deserializeFloatImpl()
	{
		mdfloat v = void;
		get(mInput, v);
		pushFloat(t, v);
	}
	
	void deserializeChar()
	{
		checkTag(MDValue.Type.Char);
		deserializeCharImpl();
	}

	void deserializeCharImpl()
	{
		pushChar(t, cast(dchar)integer());
	}

	bool checkObjTag(byte type)
	{
		auto tmp = tag();

		if(tmp == type)
			return true;
		else if(tmp == Serializer.Backref)
		{
			auto ret = mObjTable[cast(uword)integer()];
			assert(ret.mType == type);
			push(t, MDValue(ret));
			return false;
		}
		else if(tmp == Serializer.Transient)
		{
			push(t, MDValue(mTrans));
			deserializeValue();
			idx(t, -2);
			insertAndPop(t, -2);

			if(.type(t, -1) != type)
				throwException(t, "Invalid transient table");

			return false;
		}
		else
			throwException(t, "Malformed data");

		assert(false);
	}

	void deserializeString()
	{
		if(checkObjTag(MDValue.Type.String))
			deserializeStringImpl();
	}

	void deserializeStringImpl()
	{
		auto len = integer();

		auto data = t.vm.alloc.allocArray!(char)(cast(uword)len);
		scope(exit) t.vm.alloc.freeArray(data);

		readExact(mInput, data);
		pushString(t, data);
		addObject(getValue(t, -1).mBaseObj);
	}

	void deserializeTable()
	{
		if(checkObjTag(MDValue.Type.Table))
			deserializeTableImpl();
	}

	void deserializeTableImpl()
	{
		auto len = integer();

		auto v = newTable(t);
		addObject(getValue(t, -1).mBaseObj);

		for(uword i = 0; i < len; i++)
		{
			deserializeValue();
			deserializeValue();
			idxa(t, v);
		}
	}

	void deserializeArray()
	{
		if(checkObjTag(MDValue.Type.Array))
			deserializeArrayImpl();
	}

	void deserializeArrayImpl()
	{
		auto arr = t.vm.alloc.allocate!(MDArray);
		addObject(cast(MDBaseObject*)arr);

		auto len = integer();
		auto v = newArray(t, cast(uword)len);

		for(uword i = 0; i < len; i++)
		{
			deserializeValue();
			idxai(t, v, cast(mdint)i);
		}
	}

	void deserializeFunction()
	{
		if(checkObjTag(MDValue.Type.Function))
			deserializeFunctionImpl();
	}

	void deserializeFunctionImpl()
	{
		auto numUpvals = cast(uword)integer();
		auto func = t.vm.alloc.allocate!(MDFunction)(func.ScriptClosureSize(numUpvals));
		addObject(cast(MDBaseObject*)func);

		func.isNative = false;
		func.numUpvals = numUpvals;
		deserializeString();
		func.name = getStringObj(t, -1);
		pop(t);
		deserializeFuncDef();
		func.scriptFunc = getValue(t, -1).mFuncDef;
		pop(t);

		bool haveEnv;
		get(mInput, haveEnv);

		if(haveEnv)
			deserializeNamespace();
		else
			pushGlobal(t, "_G");

		func.environment = getNamespace(t, -1);
		pop(t);

		foreach(ref val; func.scriptUpvals())
		{
			deserializeUpval();
			val = cast(MDUpval*)getValue(t, -1).mBaseObj;
			pop(t);
		}

		push(t, MDValue(func));
	}

	void deserializeUpval()
	{
		if(checkObjTag(MDValue.Type.Upvalue))
			deserializeUpvalImpl();
	}

	void deserializeUpvalImpl()
	{
		auto uv = t.vm.alloc.allocate!(MDUpval)();
		addObject(cast(MDBaseObject*)uv);
		uv.value = &uv.closedValue;
		deserializeValue();
		uv.closedValue = *getValue(t, -1);
		pop(t);
		push(t, MDValue(cast(MDBaseObject*)uv));
	}

	void deserializeFuncDef()
	{
		if(checkObjTag(MDValue.Type.FuncDef))
			deserializeFuncDefImpl();
	}

	void deserializeFuncDefImpl()
	{
		auto def = t.vm.alloc.allocate!(MDFuncDef);
		addObject(cast(MDBaseObject*)def);

		deserializeString();
		def.location.file = getStringObj(t, -1);
		pop(t);
		integer(def.location.line);
		integer(def.location.col);
		get(mInput, def.isVararg);
		deserializeString();
		def.name = getStringObj(t, -1);
		pop(t);
		integer(def.numParams);
		t.vm.alloc.resizeArray(def.paramMasks, cast(uword)integer());

		foreach(ref mask; def.paramMasks)
			integer(mask);

		integer(def.numUpvals);
		integer(def.stackSize);
		t.vm.alloc.resizeArray(def.innerFuncs, cast(uword)integer());

		foreach(ref func; def.innerFuncs)
		{
			deserializeFuncDef();
			func = getValue(t, -1).mFuncDef;
			pop(t);
		}

		t.vm.alloc.resizeArray(def.constants, cast(uword)integer());

		foreach(ref val; def.constants)
		{
			deserializeValue();
			val = *getValue(t, -1);
			pop(t);
		}

		t.vm.alloc.resizeArray(def.code, cast(uword)integer());
		readExact(mInput, def.code);

		bool haveEnvironment;
		get(mInput, haveEnvironment);
		
		if(haveEnvironment)
		{
			deserializeNamespace();
			def.environment = getNamespace(t, -1);
			pop(t);
		}
		else
			def.environment = null;

		bool haveCached;
		get(mInput, haveCached);

		if(haveCached)
		{
			deserializeFunction();
			def.cachedFunc = getFunction(t, -1);
			pop(t);
		}
		else
			def.cachedFunc = null;

		t.vm.alloc.resizeArray(def.switchTables, cast(uword)integer());

		foreach(ref st; def.switchTables)
		{
			auto numOffsets = cast(uword)integer();

			for(uword i = 0; i < numOffsets; i++)
			{
				deserializeValue();
				integer(*st.offsets.insert(t.vm.alloc, *getValue(t, -1)));
				pop(t);
			}

			integer(st.defaultOffset);
		}

		t.vm.alloc.resizeArray(def.lineInfo, cast(uword)integer());
		readExact(mInput, def.lineInfo);

		t.vm.alloc.resizeArray(def.upvalNames, cast(uword)integer());

		foreach(ref name; def.upvalNames)
		{
			deserializeString();
			name = getStringObj(t, -1);
			pop(t);
		}

		t.vm.alloc.resizeArray(def.locVarDescs, cast(uword)integer());

		foreach(ref desc; def.locVarDescs)
		{
			deserializeString();
			desc.name = getStringObj(t, -1);
			pop(t);
			integer(desc.pcStart);
			integer(desc.pcEnd);
			integer(desc.reg);
		}

		push(t, MDValue(cast(MDBaseObject*)def));
	}

	void deserializeClass()
	{
		if(checkObjTag(MDValue.Type.Class))
			deserializeClassImpl();
	}

	void deserializeClassImpl()
	{
    	auto cls = t.vm.alloc.allocate!(MDClass)();
    	addObject(cast(MDBaseObject*)cls);

    	deserializeString();
		cls.name = getStringObj(t, -1);
		pop(t);

		bool haveParent;
		get(mInput, haveParent);

		if(haveParent)
		{
			deserializeClass();
			cls.parent = getClass(t, -1);
			pop(t);
		}
		else
			cls.parent = null;

		deserializeNamespace();
		cls.fields = getNamespace(t, -1);
		pop(t);

		assert(!cls.parent || cls.fields.parent);

		push(t, MDValue(cls));
	}

	void deserializeInstance()
	{
		if(checkObjTag(MDValue.Type.Instance))
			deserializeInstanceImpl();
	}

	void deserializeInstanceImpl()
	{
		auto numValues = cast(uword)integer();
		auto extraBytes = cast(uword)integer();

		// if it was custom-allocated, we can't necessarily do this.
		// well, can we?  I mean technically, a custom allocator can't do anything *terribly* weird,
		// like using malloc.. and besides, we wouldn't know what params to call it with.
		// I suppose we can assume that if a class writer is providing an opDeserialize method, they're
		// going to expect this.
		auto inst = t.vm.alloc.allocate!(MDInstance)(instance.InstanceSize(numValues, extraBytes));
		inst.numValues = numValues;
		inst.extraBytes = extraBytes;
		inst.extraValues()[] = MDValue.nullValue;
		addObject(cast(MDBaseObject*)inst);

		deserializeClass();
		inst.parent = getClass(t, -1);
		pop(t);

		bool isSpecial;
		get(mInput, isSpecial);

		if(isSpecial)
		{
			push(t, MDValue(inst));

			if(!hasMethod(t, -1, "opDeserialize"))
			{
				pushToString(t, -1, true);
				throwException(t, "'{}' was serialized with opSerialize, but does not have a matching opDeserialize", getString(t, -1));
			}

			pushNull(t);
			push(t, MDValue(mStream));
			push(t, MDValue(mDeserializeFunc));
			methodCall(t, -4, "opDeserialize", 0);
		}
		else
		{
			assert(numValues == 0 && extraBytes == 0);

			bool haveFields;
			get(mInput, haveFields);

			if(haveFields)
			{
				deserializeNamespace();
				inst.fields = getNamespace(t, -1);
				pop(t);
			}
		}

		push(t, MDValue(inst));
	}

	void deserializeNamespace()
	{
		if(checkObjTag(MDValue.Type.Namespace))
			deserializeNamespaceImpl();
	}

	void deserializeNamespaceImpl()
	{
		auto ns = t.vm.alloc.allocate!(MDNamespace);
		addObject(cast(MDBaseObject*)ns);

		deserializeString();
		ns.name = getStringObj(t, -1);
		pop(t);
		push(t, MDValue(ns));

		bool haveParent;
		get(mInput, haveParent);

		if(haveParent)
		{
			deserializeNamespace();
			ns.parent = getNamespace(t, -1);
			pop(t);
		}
		else
			ns.parent = null;

		auto len = cast(uword)integer();

		for(uword i = 0; i < len; i++)
		{
			deserializeString();
			deserializeValue();
			fielda(t, -3);
		}
	}

	void deserializeThread()
	{
		if(checkObjTag(MDValue.Type.Thread))
			deserializeThreadImpl();
	}

	void deserializeThreadImpl()
	{
		auto ret = t.vm.alloc.allocate!(MDThread);
		addObject(cast(MDBaseObject*)ret);
		ret.vm = t.vm;

		bool isExtended;
		get(mInput, isExtended);

		version(MDExtendedCoro)
		{
			if(!isExtended)
				throwException(t, "Attempting to deserialize a non-extended coroutine, but extended coroutine support was compiled in");

			// not sure how to handle deserialization of extended coros yet..
			// the issue is that we have to somehow create a ThreadFiber object and have it resume from where
			// it yielded...?  is that even possible?
			throwException(t, "AGH I don't know how to deserialize extended coros");
		}
		else
		{
			if(isExtended)
				throwException(t, "Attempting to deserialize an extended coroutine, but extended coroutine support was not compiled in");

			integer(ret.savedCallDepth);
		}

		integer(ret.arIndex);
		t.vm.alloc.resizeArray(ret.actRecs, ret.arIndex < 10 ? 10 : ret.arIndex);

		if(ret.arIndex > 0)
			ret.currentAR = &ret.actRecs[ret.arIndex - 1];
		else
			ret.currentAR = null;

		foreach(ref rec; ret.actRecs[0 .. ret.arIndex])
		{
			integer(rec.base);
			integer(rec.savedTop);
			integer(rec.vargBase);
			integer(rec.returnSlot);

			bool haveFunc;
			get(mInput, haveFunc);

			if(haveFunc)
			{
				deserializeFunction();
				rec.func = getFunction(t, -1);
				pop(t);

				uword diff;
				integer(diff);
				rec.pc = rec.func.scriptFunc.code.ptr + diff;
			}
			else
			{
				rec.func = null;
				rec.pc = null;
			}

			integer(rec.numReturns);

			bool haveProto;
			get(mInput, haveProto);

			if(haveProto)
			{
				deserializeClass();
				rec.proto = getClass(t, -1);
				pop(t);
			}
			else
				rec.proto = null;

			integer(rec.numTailcalls);
			integer(rec.firstResult);
			integer(rec.numResults);
			integer(rec.unwindCounter);

			bool haveUnwindRet;
			get(mInput, haveUnwindRet);

			if(haveUnwindRet)
			{
				uword diff;
				integer(diff);
				rec.unwindReturn = rec.func.scriptFunc.code.ptr + diff;
			}
			else
				rec.unwindReturn = null;
		}

		integer(ret.trIndex);
		t.vm.alloc.resizeArray(ret.tryRecs, ret.trIndex < 10 ? 10 : ret.trIndex);

		if(ret.trIndex > 0)
			ret.currentTR = &ret.tryRecs[ret.trIndex - 1];
		else
			ret.currentTR = null;

		foreach(ref rec; ret.tryRecs[0 .. ret.trIndex])
		{
			get(mInput, rec.isCatch);
			integer(rec.slot);
			integer(rec.actRecord);

			uword diff;
			integer(diff);
			rec.pc = ret.actRecs[rec.actRecord].func.scriptFunc.code.ptr + diff;
		}

		integer(ret.stackIndex);

		uword stackTop;
		integer(stackTop);
		t.vm.alloc.resizeArray(ret.stack, stackTop < 20 ? 20 : stackTop);

		foreach(ref val; ret.stack[0 .. stackTop])
		{
			deserializeValue();
			val = *getValue(t, -1);
			pop(t);
		}

		integer(ret.stackBase);
		integer(ret.resultIndex);
		t.vm.alloc.resizeArray(ret.results, ret.resultIndex < 8 ? 8 : ret.resultIndex);

		foreach(ref val; ret.results[0 .. ret.resultIndex])
		{
			deserializeValue();
			val = *getValue(t, -1);
			pop(t);
		}

		get(mInput, ret.shouldHalt);

		bool haveCoroFunc;
		get(mInput, haveCoroFunc);

		if(haveCoroFunc)
		{
			deserializeFunction();
			ret.coroFunc = getFunction(t, -1);
			pop(t);
		}
		else
			ret.coroFunc = null;

		integer(ret.state);
		integer(ret.numYields);

		// TODO: hooks?!

		auto next = &t.upvalHead;

		while(true)
		{
			deserializeValue();

			if(isNull(t, -1))
			{
				pop(t);
				break;
			}

			auto uv = cast(MDUpval*)getValue(t, -1).mBaseObj;
			pop(t);
			
			uword diff;
			integer(diff);
			
			uv.value = ret.stack.ptr + diff;
			*next = uv;
			next = &uv.nextuv;
		}

		*next = null;

		pushThread(t, ret);
	}

	void deserializeWeakref()
	{
		if(checkObjTag(MDValue.Type.WeakRef))
			deserializeWeakrefImpl();
	}

	void deserializeWeakrefImpl()
	{
		auto wr = t.vm.alloc.allocate!(MDWeakRef);
		wr.obj = null;
		addObject(cast(MDBaseObject*)wr);

		bool isNull;
		get(mInput, isNull);

		if(!isNull)
		{
			deserializeValue();
			wr.obj = getValue(t, -1).mBaseObj;
			pop(t);
			*t.vm.weakRefTab.insert(t.vm.alloc, wr.obj) = wr;
		}
		
		push(t, MDValue(wr));
	}

	void addObject(MDBaseObject* v)
	{
		t.vm.alloc.resizeArray(mObjTable, mObjTable.length + 1);
		mObjTable[$ - 1] = v;
	}
}

void get(T)(InputStream i, ref T ret)
{
	if(i.read(cast(void[])(&ret)[0 .. 1]) != T.sizeof)
		throw new IOException("End of stream while reading");
}

void put(T)(OutputStream o, T val)
{
	if(o.write(cast(void[])(&val)[0 .. 1]) != T.sizeof)
		throw new IOException("End of stream while writing");
}

void readExact(InputStream i, void[] dest)
{
	if(i.read(dest) != dest.length)
		throw new IOException("End of stream while reading");
}

void append(OutputStream o, void[] val)
{
	if(o.write(val) != val.length)
		throw new IOException("End of stream while writing");
}