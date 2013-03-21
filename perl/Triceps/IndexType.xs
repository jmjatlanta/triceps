//
// (C) Copyright 2011-2013 Sergey A. Babkin.
// This file is a part of Triceps.
// See the file COPYRIGHT for the copyright notice and license information
//
// The wrapper for IndexType.

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#include "TricepsPerl.h"
#include "PerlCallback.h"
#include "PerlAggregator.h"
#include "PerlSortCondition.h"

MODULE = Triceps::IndexType		PACKAGE = Triceps::IndexType
###################################################################################

int
CLONE_SKIP(...)
	CODE:
		RETVAL = 1;
	OUTPUT:
		RETVAL

void
DESTROY(WrapIndexType *self)
	CODE:
		// warn("IndexType destroyed!");
		delete self;


# create a HashedIndex
# options go in pairs  name => value 
WrapIndexType *
newHashed(char *CLASS, ...)
	CODE:
		static char funcName[] =  "Triceps::IndexType::newHashed";
		clearErrMsg();

		Autoref<NameSet> key;

		if (items % 2 != 1) {
			setErrMsg(strprintf("Usage: %s(CLASS, optionName, optionValue, ...), option names and values must go in pairs", funcName));
			XSRETURN_UNDEF;
		}
		for (int i = 1; i < items; i += 2) {
			const char *opt = (const char *)SvPV_nolen(ST(i));
			SV *val = ST(i+1);
			if (!strcmp(opt, "key")) {
				if (!key.isNull()) {
					setErrMsg(strprintf("%s: option 'key' can not be used twice", funcName));
					XSRETURN_UNDEF;
				}
				key = parseNameSet(funcName, "key", val);
				if (key.isNull()) // error message already set
					XSRETURN_UNDEF;
			} else {
				setErrMsg(strprintf("%s: unknown option '%s'", funcName, opt));
				XSRETURN_UNDEF;
			}
		}

		if (key.isNull()) {
			setErrMsg(strprintf("%s: the required option 'key' is missing", funcName));
			XSRETURN_UNDEF;
		}

		RETVAL = new WrapIndexType(new HashedIndexType(key));
	OUTPUT:
		RETVAL

# create a FifoIndex
# options go in pairs  name => value 
WrapIndexType *
newFifo(char *CLASS, ...)
	CODE:
		static char funcName[] =  "Triceps::IndexType::newFifo";
		clearErrMsg();

		size_t limit = 0;
		bool jumping = false;
		bool reverse = false;

		if (items % 2 != 1) {
			setErrMsg(strprintf("Usage: %s(CLASS, optionName, optionValue, ...), option names and values must go in pairs", funcName));
			XSRETURN_UNDEF;
		}
		for (int i = 1; i < items; i += 2) {
			const char *opt = (const char *)SvPV_nolen(ST(i));
			SV *val = ST(i+1);
			if (!strcmp(opt, "limit")) { // XXX should it check for < 0?
				limit = SvIV(val); // may overflow if <0 but we don't care
			} else if (!strcmp(opt, "jumping")) {
				jumping = SvIV(val);
			} else if (!strcmp(opt, "reverse")) {
				reverse = SvIV(val);
			} else {
				setErrMsg(strprintf("%s: unknown option '%s'", funcName, opt));
				XSRETURN_UNDEF;
			}
		}

		RETVAL = new WrapIndexType(new FifoIndexType(limit, jumping, reverse));
	OUTPUT:
		RETVAL

# create a PerlSortedIndex
# that uses a Perl comparison function
# @param CLASS - name of type being constructed
# @param sortName - name of the sort condition (for messages about comparator fatal errors)
# @param initialize - function reference used to perform the index type initialization,
#        may be undef if the compare argument is defined, may be
#        used to check that the args make sense and generate the compare callback on the fly.
#        Args: TableType tabt, IndexType idxt, RowType rowt
#          tabt - table type that performs the initialization
#          idxt - link back to the index type that contains the condition (used to
#                 set the compare callback and such)
#          rowt - row type of the table, passed directly as a convenience
#        Returns undef on success or an error message (may freely contain \n) on error.
# @param compare - function reference used to compare the keys for the sorting order,
#        may be undef if the initialize argument is defined and will use setComparator()
#        at initialization time, having it still undefined after initialization is an error..
#        Args: Row r1, Row r2.
#        Returns the result of r1 <=> r2.
# @param ... - extra args used for both initialize and compare functions
WrapIndexType *
newPerlSorted(char *CLASS, char *sortName, SV *initialize, SV *compare, ...)
	CODE:
		static char funcName[] =  "Triceps::IndexType::newPerlSorted";
		clearErrMsg();

		Onceref<PerlCallback> cbInit; // defaults to NULL
		if (SvOK(initialize)) {
			cbInit = new PerlCallback();
			PerlCallbackInitializeSplit(cbInit, "Triceps::IndexType::newPerlSorted(initialize)", initialize, 4, items-4);
			if (cbInit->code_ == NULL)
				XSRETURN_UNDEF; // error message is already set
		}

		Onceref<PerlCallback> cbCompare; // defaults to NULL
		if (SvOK(compare)) {
			cbCompare = new PerlCallback();
			PerlCallbackInitializeSplit(cbCompare, "Triceps::IndexType::newPerlSorted(compare)", compare, 4, items-4);
			if (cbCompare->code_ == NULL)
				XSRETURN_UNDEF; // error message is already set
		}

		if (cbInit.isNull() && cbCompare.isNull()) {
			setErrMsg(strprintf("%s: at least one of init and comparator function arguments must be not undef", funcName));
			XSRETURN_UNDEF;
		}

		RETVAL = new WrapIndexType(new SortedIndexType(new PerlSortCondition(sortName, cbInit, cbCompare)));
	OUTPUT:
		RETVAL

# make an uninitialized copy
WrapIndexType *
copy(WrapIndexType *self)
	CODE:
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();
		RETVAL = new WrapIndexType(ixt->copy());
	OUTPUT:
		RETVAL

int
same(WrapIndexType *self, WrapIndexType *other)
	CODE:
		clearErrMsg();
		IndexType *ixself = self->get();
		IndexType *ixother = other->get();
		RETVAL = (ixself == ixother);
	OUTPUT:
		RETVAL

# print(self, [ indent, [ subindent ] ])
#   indent - default "", undef means "print everything in a signle line"
#   subindent - default "  "
SV *
print(WrapIndexType *self, ...)
	PPCODE:
		GEN_PRINT_METHOD(IndexType)

# type comparisons
int
equals(WrapIndexType *self, WrapIndexType *other)
	CODE:
		clearErrMsg();
		IndexType *ixself = self->get();
		IndexType *ixother = other->get();
		RETVAL = ixself->equals(ixother);
	OUTPUT:
		RETVAL

int
match(WrapIndexType *self, WrapIndexType *other)
	CODE:
		clearErrMsg();
		IndexType *ixself = self->get();
		IndexType *ixother = other->get();
		RETVAL = ixself->match(ixother);
	OUTPUT:
		RETVAL

# check if leaf
int
isLeaf(WrapIndexType *self)
	CODE:
		clearErrMsg();
		IndexType *ixt = self->get();
		RETVAL = ixt->isLeaf();
	OUTPUT:
		RETVAL

# add a nested index
# XXX accept multiple subname-sub pairs as arguments
WrapIndexType *
addSubIndex(WrapIndexType *self, char *subname, WrapIndexType *sub)
	CODE:
		static char funcName[] =  "Triceps::IndexType::addSubIndex";
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();

		if (ixt->isInitialized()) {
			setErrMsg(strprintf("%s: index is already initialized, can not add indexes any more", funcName));
			XSRETURN_UNDEF;
		}

		IndexType *ixsub = sub->get();
		// can't just return self because it will upset the refcount
		RETVAL = new WrapIndexType(ixt->addSubIndex(subname, ixsub));
	OUTPUT:
		RETVAL

WrapIndexType *
setAggregator(WrapIndexType *self, WrapAggregatorType *wagg)
	CODE:
		static char funcName[] =  "Triceps::IndexType::setAggregator";
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();
		PerlAggregatorType *agg = wagg->get();

		if (ixt->isInitialized()) {
			setErrMsg(strprintf("%s: index is already initialized, can not add indexes any more", funcName));
			XSRETURN_UNDEF;
		}

		if (agg->isInitialized()) {
			setErrMsg(strprintf("%s: aggregator is already initialized, can not add to more indexes", funcName));
			XSRETURN_UNDEF;
		}

		ixt->setAggregator(agg);
		// can't just return self because it will upset the refcount
		RETVAL = new WrapIndexType(ixt);
	OUTPUT:
		RETVAL

# returns undef if no aggregator type set
WrapAggregatorType *
getAggregator(WrapIndexType *self)
	CODE:
		static char funcName[] =  "Triceps::IndexType::getAggregator";
		// for casting of return value
		static char CLASS[] = "Triceps::AggregatorType";

		clearErrMsg();
		IndexType *ixt = self->get();
		PerlAggregatorType *agg = dynamic_cast<PerlAggregatorType *>(const_cast<AggregatorType *>(ixt->getAggregator()));

		if (agg == NULL)
			XSRETURN_UNDEF;
		RETVAL = new WrapAggregatorType(agg);
	OUTPUT:
		RETVAL

# find a nested index by name
WrapIndexType *
findSubIndex(WrapIndexType *self, char *subname)
	CODE:
		static char funcName[] =  "Triceps::IndexType::findSubIndex";
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();
		IndexType *ixsub = ixt->findSubIndex(subname);
		if (ixsub == NULL) {
			setErrMsg(strprintf("%s: unknown nested index '%s'", funcName, subname));
			XSRETURN_UNDEF;
		}
		RETVAL = new WrapIndexType(ixsub);
	OUTPUT:
		RETVAL

# find a nested index by type id
WrapIndexType *
findSubIndexById(WrapIndexType *self, SV *idarg)
	CODE:
		static char funcName[] =  "Triceps::IndexType::findSubIndexById";
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();

		IndexType::IndexId id;
		if (!parseIndexId(funcName, idarg, id))
			XSRETURN_UNDEF;

		IndexType *ixsub = ixt->findSubIndexById(id);
		if (ixsub == NULL) {
			setErrMsg(strprintf("%s: no nested index with type id '%s' (%d)", funcName, IndexType::indexIdString(id), id));
			XSRETURN_UNDEF;
		}
		RETVAL = new WrapIndexType(ixsub);
	OUTPUT:
		RETVAL

# returns an array of paired values (name => type)
SV *
getSubIndexes(WrapIndexType *self)
	PPCODE:
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();

		const IndexTypeVec &nested = ixt->getSubIndexes();
		for (IndexTypeVec::const_iterator it = nested.begin(); it != nested.end(); ++it) {
			const IndexTypeRef &ref = *it;
			
			XPUSHs(sv_2mortal(newSVpvn(ref.name_.c_str(), ref.name_.size())));
			SV *sub = newSV(0);
			sv_setref_pv( sub, CLASS, (void*)(new WrapIndexType(ref.index_.get())) );
			XPUSHs(sv_2mortal(sub));
		}

# get the first leaf sub-index
WrapIndexType *
getFirstLeaf(WrapIndexType *self)
	CODE:
		// for casting of return value
		static char CLASS[] = "Triceps::IndexType";

		clearErrMsg();
		IndexType *ixt = self->get();
		RETVAL = new WrapIndexType(ixt->getFirstLeaf());
	OUTPUT:
		RETVAL

# get the index type identity
int
getIndexId(WrapIndexType *self)
	CODE:
		clearErrMsg();
		IndexType *ixt = self->get();
		RETVAL = ixt->getIndexId();
	OUTPUT:
		RETVAL

# check if the type has been initialized
int
isInitialized(WrapIndexType *self)
	CODE:
		clearErrMsg();
		IndexType *ixt = self->get();
		RETVAL = ixt->isInitialized();
	OUTPUT:
		RETVAL

WrapTableType *
getTabtype(WrapIndexType *self)
	CODE:
		static char funcName[] =  "Triceps::IndexType::getTabtype";
		// for casting of return value
		static char CLASS[] = "Triceps::TableType";

		clearErrMsg();
		IndexType *ixt = self->get();
		TableType *tt = ixt->getTabtype();
		if (tt == NULL) {
			setErrMsg(strprintf("%s: this index type does not belong to an initialized table type", funcName));
			XSRETURN_UNDEF;
		}
		RETVAL = new WrapTableType(tt);
	OUTPUT:
		RETVAL

# returns the array of fields that are keys of this index
# (may be empty if the index is not keyed by fields)
SV *
getKey(WrapIndexType *self)
	PPCODE:
		clearErrMsg();
		IndexType *ixt = self->get();

		const_Autoref<NameSet> key = ixt->getKey();
		if (!key.isNull()) {
			for (NameSet::const_iterator it = key->begin(); it != key->end(); ++it) {
				const string &s = *it;
				XPUSHs(sv_2mortal(newSVpvn(s.c_str(), s.size())));
			}
		}

# For a PerlSortedIndex: set the comparator function
# @param compare - function to call to compare the row keys
# @param ... - arguments for the comparator
# @returns - 1 on success or undef on error
int
setComparator(WrapIndexType *self, SV *compare, ...)
	CODE:
		static char funcName[] =  "Triceps::IndexType::setComparator";

		clearErrMsg();
		IndexType *ixt = self->get();

		PerlSortCondition *psc = NULL;
		SortedIndexType *sit = dynamic_cast<SortedIndexType *>(ixt);
		if (sit != NULL) {
			psc = dynamic_cast<PerlSortCondition *>(sit->getCondition());
		}
		if (psc == NULL) {
			setErrMsg(strprintf("%s: this index type is not a PerlSortedIndex", funcName));
			XSRETURN_UNDEF;
		}
		
		Onceref<PerlCallback> cbCompare; // defaults to NULL
		if (SvOK(compare)) {
			cbCompare = new PerlCallback();
			PerlCallbackInitializeSplit(cbCompare, funcName, compare, 2, items-2);
			if (cbCompare->code_ == NULL)
				XSRETURN_UNDEF; // error message is already set
		}

		if (!psc->setComparator(cbCompare)) {
			setErrMsg(strprintf("%s: this index type is already initialized and can not be changed", funcName));
			XSRETURN_UNDEF;
		}
		RETVAL = 1; // success
	OUTPUT:
		RETVAL

# XXX isJumping, isReverse etc., or maybe better do it as getOptions()
