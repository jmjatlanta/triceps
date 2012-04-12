#
# (C) Copyright 2011-2012 Sergey A. Babkin.
# This file is a part of Triceps.
# See the file COPYRIGHT for the copyright notice and license information
#
# A join by performing a look-up in a table (like "stream-to-window" in CCL).

package Triceps::LookupJoin;
use Carp;

use strict;

# Options:
# unit - unit object
# name - name of this object (will be used to create the names of internal objects)
# leftRowType - type of the rows that will be used for lookup
# rightTable - table object where to do the look-ups
# rightIdxPath (optional) - array reference containing the path name of index type 
#    in table used for look-up (default: first top-level Hash),
#    index absolutely must be a Hash (leaf or not), not of any other kind
# leftFields (optional) - reference to array of patterns for left fields to pass through,
#    syntax as described in Triceps::Fields::filter(), if not defined then pass everything
# rightFields (optional) - reference to array of patterns for right fields to pass through,
#    syntax as described in Triceps::Fields::filter(), if not defined then pass everything
#    (which is probably a bad idea since it would include duplicate fields from the 
#    index, so override it)
# fieldsLeftFirst (optional) - flag: in the resulting records put the fields from
#    the left record first, then from right record, or if 0, then opposite. (default:1)
# by - reference to array, containing pairs of field names used for look-up,
#    [ leftFld1, rightFld1, leftFld2, rightFld2, ... ]
#    XXX should allow an arbitrary expression on the left?
# isLeft (optional) - 1 for left join, 0 for full join (default: 1)
# limitOne (optional) - 1 to return no more than one record, 0 otherwise (default: 0)
# automatic (optional) - 1 means that the lookup() method will never be called
#    manually, this allows to optimize the label handler and always take the opcode 
#    into account when processing the rows, 0 that lookup() will be used. (default: 1)
# oppositeOuter (optional) - used with automatic only, flag: this is a half of a JoinTwo, 
#    and the other half performs an outer (from its standpoint, left) join. For this side,
#    this means that a successfull lookup must generate a DELETE-INSERT pair.
#    (default: 0)
# saveJoinerTo (optional, ref to a scalar) - where to save a copy of the joiner function
#    source code
sub new # (class, optionName => optionValue ...)
{
	my $class = shift;
	my $self = {};

	&Triceps::Opt::parse($class, $self, {
			unit => [ undef, sub { &Triceps::Opt::ck_mandatory(@_); &Triceps::Opt::ck_ref(@_, "Triceps::Unit") } ],
			name => [ undef, \&Triceps::Opt::ck_mandatory ],
			leftRowType => [ undef, sub { &Triceps::Opt::ck_mandatory(@_); &Triceps::Opt::ck_ref(@_, "Triceps::RowType") } ],
			rightTable => [ undef, sub { &Triceps::Opt::ck_mandatory(@_); &Triceps::Opt::ck_ref(@_, "Triceps::Table") } ],
			rightIdxPath => [ undef, sub { &Triceps::Opt::ck_ref(@_, "ARRAY", "") } ],
			leftFields => [ undef, sub { &Triceps::Opt::ck_ref(@_, "ARRAY") } ],
			rightFields => [ undef, sub { &Triceps::Opt::ck_ref(@_, "ARRAY") } ],
			fieldsLeftFirst => [ 1, undef ],
			by => [ undef, sub { &Triceps::Opt::ck_mandatory(@_); &Triceps::Opt::ck_ref(@_, "ARRAY") } ],
			isLeft => [ 1, undef ],
			limitOne => [ 0, undef ],
			automatic => [ 1, undef ],
			oppositeOuter => [ 0, undef ],
			saveJoinerTo => [ undef, sub { &Triceps::Opt::ck_refscalar(@_) } ],
		}, @_);

	$self->{rightRowType} = $self->{rightTable}->getRowType();

	my $auto = $self->{automatic};

	my @leftdef = $self->{leftRowType}->getdef();
	my %leftmap = $self->{leftRowType}->getFieldMapping();
	my @leftfld = $self->{leftRowType}->getFieldNames();

	my @rightdef = $self->{rightRowType}->getdef();
	my %rightmap = $self->{rightRowType}->getFieldMapping();
	my @rightfld = $self->{rightRowType}->getFieldNames();

	# XXX use getKey() to check that the "by" keys match the
	# keys of the index (not so easy for the nested indexes because they
	# would have to include the keys in the whole path)

	my $genjoin; 
	if ($auto) {
		# Generate the input label handler with arguments:
		# @param inLabel - input label
		# @param rowop - incoming rowop
		# @param self - this object
		# @return - an array of joined rows
		$genjoin .= '
		sub # ($inLabel, $rowop, $self)';
	} else {
		# Generate the join function with arguments:
		# @param self - this object
		# @param row - row argument
		# @return - an array of joined rows
		$genjoin .= '
		sub  # ($self, $row)';
	}
	$genjoin .= '
		{'; # keep the brace counter happy, do not repeat it in 2 cases
	if ($auto) {
		$genjoin .= '
			my ($inLabel, $rowop, $self) = @_;
			#print STDERR "DEBUGX LookupJoin " . $self->{name} . " in: ", $rowop->printP(), "\n";

			my $opcode = $rowop->getOpcode(); # pass the opcode
			my $row = $rowop->getRow();

			my @leftdata = $row->toArray();

			my $resRowType = $self->{resultRowType};
			my $resLabel = $self->{outputLabel};
		';
	} else {
		$genjoin .= '
			my ($self, $row) = @_;

			#print STDERR "DEBUGX LookupJoin " . $self->{name} . " in: ", $row->printP(), "\n";

			my @leftdata = $row->toArray();
		';
	}

	# create the look-up row (and check that "by" contains the correct field names)
	$genjoin .= '
			my $lookuprow = $self->{rightRowType}->makeRowHash(
				';
	my @cpby = @{$self->{by}};
	while ($#cpby >= 0) {
		my $lf = shift @cpby;
		my $rt = shift @cpby;
		Carp::confess("Option 'by' contains an unknown left-side field '$lf'")
			unless defined $leftmap{$lf};
		Carp::confess("Option 'by' contains an unknown right-side field '$rt'")
			unless defined $rightmap{$rt};
		my $lf_type = $leftdef[$leftmap{$lf}*2 + 1];
		my $rt_type = $rightdef[$rightmap{$rt}*2 + 1];
		my $lf_arr = &Triceps::Fields::isArrayType($lf_type);
		my $rt_arr = &Triceps::Fields::isArrayType($rt_type);

		Carp::confess("Option 'by' fields '$lf'='$rt' mismatch the array-ness, with types '$lf_type' and '$rt_type'")
			unless ($lf_arr == $rt_arr);
		
		$genjoin .= $rt . ' => $leftdata[' . $leftmap{$lf} . "],\n\t\t\t\t";
	}
	$genjoin .= ");\n\t\t\t";

	# translate the index
	if (defined $self->{rightIdxPath}) {
		$self->{rightIdxType} = $self->{rightTable}->getType()->findIndexPath(@{$self->{rightIdxPath}});
		# if not found, would already confess
		my $ixid  = $self->{rightIdxType}->getIndexId();
		Carp::confess("The index '" . join('.', @{$self->{rightIdxPath}}) . "' is of kind '" . &Triceps::indexIdString($ixid) . "', not the required 'IT_HASHED'")
			unless ($ixid == &Triceps::IT_HASHED);
	} else {
		$self->{rightIdxType} = $self->{rightTable}->getType()->findSubIndexById(&Triceps::IT_HASHED);
		Carp::confess("The rightTable does not have a top-level Hash index for joining")
			unless defined $self->{rightIdxType};
	}
	if (!$self->{limitOne}) { # would need a sub-index for iteration
		my @subs = $self->{rightIdxType}->getSubIndexes();
		if ($#subs < 0) { # no sub-indexes, so guaranteed to match one record
			#print STDERR "DEBUG auto-deducing limitOne=1 subs=(", join(", ", @subs), ")\n";
			$self->{limitOne} = 1;
		} else {
			$self->{iterIdxType} = $subs[1]; # first index type object, they go in (name => type) pairs
			# (all sub-indexes are equivalent for our purpose, just pick first)
		}
	}

	##########################################################################
	# build the code that will produce one result record by combining
	# @leftdata and @rightdata into @resdata;
	# also for oppositeOuter add a special case for the opposite opcode 
	# and empty right data in @oppdata

	my $genresdata .= '
				my @resdata = (';
	my $genoppdata .= '
				my @oppdata = ('; # for oppositeOuter
	my @resultdef;
	my %resultmap; 
	my @resultfld;
	
	# reference the variables for access by left/right iterator
	my %choice = (
		leftdef => \@leftdef,
		leftmap => \%leftmap,
		leftfld => \@leftfld,
		rightdef => \@rightdef,
		rightmap => \%rightmap,
		rightfld => \@rightfld,
	);
	my @order = ($self->{fieldsLeftFirst} ? ("left", "right") : ("right", "left"));
	#print STDERR "DEBUG order is ", $self->{fieldsLeftFirst}, ": (", join(", ", @order), ")\n";
	for my $side (@order) {
		my $orig = $choice{"${side}fld"};
		my @trans = &Triceps::Fields::filter($orig, $self->{"${side}Fields"});
		my $smap = $choice{"${side}map"};
		for (my $i = 0; $i <= $#trans; $i++) {
			my $f = $trans[$i];
			#print STDERR "DEBUG ${side} [$i] is '" . (defined $f? $f : '-undef-') . "'\n";
			next unless defined $f;
			if (exists $resultmap{$f}) {
				Carp::confess("A duplicate field '$f' is produced from  ${side}-side field '"
					. $orig->[$i] . "'; the preceding fields are: (" . join(", ", @resultfld) . ")" )
			}
			my $index = $smap->{$orig->[$i]};
			#print STDERR "DEBUG   index=$index smap=(" . join(", ", %$smap) . ")\n";
			push @resultdef, $f, $choice{"${side}def"}->[$index*2 + 1];
			push @resultfld, $f;
			$resultmap{$f} = $#resultfld; # fix the index
			$genresdata .= '$' . $side . 'data[' . $index . "],\n\t\t\t\t";
			if ($side eq "right") {
				$genoppdata .= '$' . $side . 'data[' . $index . "],\n\t\t\t\t";
			} else {
				$genoppdata .= "undef,\n\t\t\t\t"; # empty filler for left (our) side
			}
		}
	}
	$genresdata .= ");";
	
	if ($auto) { # in the auto mode don't collect rows, call them right away
		$genresdata .= '
				my $resrowop = $resLabel->makeRowop($opcode, $resRowType->makeRowArray(@resdata));
				#print STDERR "DEBUGX " . $self->{name} . " +out: ", $resrowop->printP(), "\n";
				Carp::confess("$!") unless defined $resrowop;
				Carp::confess("$!") 
					unless $resLabel->getUnit()->call($resrowop);
				';
	} else {
		$genresdata .= '
				push @result, $self->{resultRowType}->makeRowArray(@resdata);
				#print STDERR "DEBUGX " . $self->{name} . " +out: ", $result[$#result]->printP(), "\n";';
	}

	# genoppdata will only be used with $auto mode
	$genoppdata .= ');
				my $opprowop = $resLabel->makeRowop(
					&Triceps::isInsert($opcode)? &Triceps::OP_DELETE : &Triceps::OP_INSERT,
					, $resRowType->makeRowArray(@oppdata));
				#print STDERR "DEBUGX " . $self->{name} . " +out: ", $opprowop->printP(), "\n";
				Carp::confess("$!") unless defined $opprowop;
				Carp::confess("$!") 
					unless $resLabel->getUnit()->call($opprowop);
				';

	# end of result record
	##########################################################################

	# do the look-up
	$genjoin .= '
			#print STDERR "DEBUGX " . $self->{name} . " lookup: ", $lookuprow->printP(), "\n";
			my $rh = $self->{rightTable}->findIdx($self->{rightIdxType}, $lookuprow);
			Carp::confess("$!") unless defined $rh;
		';
	$genjoin .= '
			my @rightdata; # fields from the right side, defaults to all-undef, if no data found
			my @result; # the result rows will be collected here
		';
	if ($self->{limitOne}) { # an optimized version that returns no more than one row
		if (! $self->{isLeft}) {
			# a shortcut for full join if nothing is found
			$genjoin .= '
			return () if $rh->isNull();
			#print STDERR "DEBUGX " . $self->{name} . " found data: " . $rh->getRow()->printP() . "\n";
			@rightdata = $rh->getRow()->toArray();
';
		} else {
			$genjoin .= '
			if (!$rh->isNull()) {
				#print STDERR "DEBUGX " . $self->{name} . " found data: " . $rh->getRow()->printP() . "\n";
				@rightdata = $rh->getRow()->toArray();
			}
';
		}
		if ($auto && $self->{oppositeOuter}) {
			$genjoin .= '
			if (!$rh->isNull()) {
				if (&Triceps::isInsert($opcode)) {
' . $genoppdata . '
' . $genresdata . '
				} elsif (&Triceps::isDelete($opcode)) {
' . $genresdata . '
' . $genoppdata . '
				}
			} else {
' . $genresdata . '
			}
';
		} else {
			$genjoin .= $genresdata;
		}
	} else {
		$genjoin .= '
			if ($rh->isNull()) {
				#print STDERR "DEBUGX " . $self->{name} . " found NULL\n";
'; 
		if ($self->{isLeft}) {
			$genjoin .= $genresdata;
		} else {
			$genjoin .= '
				return ();';
		}

		$genjoin .= '
			} else {
				#print STDERR "DEBUGX " . $self->{name} . " found data: " . $rh->getRow()->printP() . "\n";
				my $endrh = $self->{rightTable}->nextGroupIdx($self->{iterIdxType}, $rh);
				for (; !$rh->same($endrh); $rh = $self->{rightTable}->nextIdx($self->{rightIdxType}, $rh)) {
					@rightdata = $rh->getRow()->toArray();';
		if ($auto && $self->{oppositeOuter}) {
			$genjoin .= '
					if (&Triceps::isInsert($opcode)) {
' . $genoppdata . '
' . $genresdata . '
					} elsif (&Triceps::isDelete($opcode)) {
' . $genresdata . '
' . $genoppdata . '
					}
';
		} else {
			$genjoin .= $genresdata;
		}
		$genjoin .= '
				}
			}';
	}

	if (!$auto) {
		$genjoin .= '
			return @result;';
	}
	$genjoin .= '
		}'; # end of function

	#print STDERR "DEBUG $genjoin\n";

	${$self->{saveJoinerTo}} = $genjoin if (defined($self->{saveJoinerTo}));
	undef $@;
	if ($auto) {
		$self->{joinerAutomatic} = eval $genjoin; # compile!
	} else {
		$self->{joiner} = eval $genjoin; # compile!
	}
	Carp::confess("Internal error: LookupJoin failed to compile the joiner function:\n$@\nfunction text:\n$genjoin ")
		if $@;

	# now create the result row type
	#print STDERR "DEBUG result type def = (", join(", ", @resultdef), ")\n"; # DEBUG
	$self->{resultRowType} = Triceps::RowType->new(@resultdef);
	Carp::confess("$!") unless (ref $self->{resultRowType} eq "Triceps::RowType");

	# create the input label
	$self->{inputLabel} = $self->{unit}->makeLabel($self->{leftRowType}, $self->{name} . ".in", 
		undef, $auto? $self->{joinerAutomatic} : \&handleInput, $self);
	Carp::confess("$!") unless (ref $self->{inputLabel} eq "Triceps::Label");
	# create the output label
	$self->{outputLabel} = $self->{unit}->makeDummyLabel($self->{resultRowType}, $self->{name} . ".out");
	Carp::confess("$!") unless (ref $self->{outputLabel} eq "Triceps::Label");

	bless $self, $class;
	return $self;
}

# Perofrm the look-up by left row in the right table and return the
# result rows(s).
# @param self
# @param leftRow - left-side row for performing the look-up
# @return - array of result rows (if not isLeft then may be empty)
sub lookup # (self, leftRow)
{
	my ($self, $leftRow) = @_;
	confess("Joiner '" . $self->{name} . "' was created with automatic option and does not support the manual lookup() call")
		if ($self->{automatic});
	my @result = &{$self->{joiner}}($self, $leftRow);
	#print STDERR "DEBUG lookup result=(", join(", ", @result), ")\n";
	return @result;
}

# Handle the input records 
# @param label - input label
# @param rowop - incoming row
# @param self - this object
sub handleInput # ($label, $rowop, $self)
{
	my ($label, $rowop, $self) = @_;

	my $opcode = $rowop->getOpcode(); # pass the opcode

	# if many rows get selected, this may result in a huge array,
	# but then again, in any case the rowops would need to be created for all of them
	my @resRows = &{$self->{joiner}}($self, $rowop->getRow());
	my $resultLab = $self->{outputLabel};
	my $resultRowop;
	foreach my $resultRow( @resRows ) {
		$resultRowop = $resultLab->makeRowop($opcode, $resultRow);
		Carp::confess("$!") unless defined $resultRowop;
		Carp::confess("$!") 
			unless $resultLab->getUnit()->call($resultRowop);
	}
}

sub getResultRowType # (self)
{
	my $self = shift;
	return $self->{resultRowType};
}

sub getInputLabel # (self)
{
	my $self = shift;
	return $self->{inputLabel};
}

sub getOutputLabel # (self)
{
	my $self = shift;
	return $self->{outputLabel};
}

sub getUnit # (self)
{
	my $self = shift;
	return $self->{unit};
}

sub getName # (self)
{
	my $self = shift;
	return $self->{name};
}

sub getLeftRowType # (self)
{
	my $self = shift;
	return $self->{leftRowType};
}

sub getRightTable # (self)
{
	my $self = shift;
	return $self->{rightTable};
}

sub getRightIdxPath # (self)
{
	my $self = shift;
	return $self->{rightIdxPath};
}

sub getLeftFields # (self)
{
	my $self = shift;
	return $self->{leftFields};
}

sub getRightFields # (self)
{
	my $self = shift;
	return $self->{rightFields};
}

sub getFieldsLeftFirst # (self)
{
	my $self = shift;
	return $self->{fieldsLeftFirst};
}

sub getBy # (self)
{
	my $self = shift;
	return $self->{by};
}

sub getIsLeft # (self)
{
	my $self = shift;
	return $self->{isLeft};
}

sub getLimitOne # (self)
{
	my $self = shift;
	return $self->{limitOne};
}

sub getAutomatic # (self)
{
	my $self = shift;
	return $self->{automatic};
}

sub getOppositeOuter # (self)
{
	my $self = shift;
	return $self->{oppositeOuter};
}

1;