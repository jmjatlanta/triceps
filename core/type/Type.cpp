//
// This file is a part of Biceps.
// See the file COPYRIGHT for the copyright notice and license information
//

#include <type/AllSimpleTypes.h>
#include <string.h>

namespace BICEPS_NS {

Autoref<const SimpleType> Type::r_void(new VoidType);
Autoref<const SimpleType> Type::r_uint8(new Uint8Type);
Autoref<const SimpleType> Type::r_int32(new Int32Type);
Autoref<const SimpleType> Type::r_int64(new Int64Type);
Autoref<const SimpleType> Type::r_float64(new Float64Type);
Autoref<const SimpleType> Type::r_string(new StringType);

const Onceref<const SimpleType> Type::findSimpleType(const char *name)
{
	if (name == NULL)
		return NULL;
	char c = name[0];
	if (c <= 'i') {
		switch(c) {
		case 'f':
			if (!strcmp(name, "float64"))
				return r_float64;
			break;
		default:
			if (!strcmp(name, "int32"))
				return r_int32;
			if (!strcmp(name, "int64"))
				return r_int64;
			break;
		}
	} else {
		switch(c) {
		case 's':
			if (!strcmp(name, "string"))
				return r_string;
			break;
		case 'u':
			if (!strcmp(name, "uint8"))
				return r_uint8;
			break;
		default:
			if (!strcmp(name, "void"))
				return r_void;
			break;
		}
	}
	return NULL;
}

}; // BICEPS_NS
