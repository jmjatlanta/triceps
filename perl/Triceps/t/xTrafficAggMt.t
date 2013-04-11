#
# (C) Copyright 2011-2013 Sergey A. Babkin.
# This file is a part of Triceps.
# See the file COPYRIGHT for the copyright notice and license information
#
# An example of traffic accounting aggregated to multiple levels,
# as a multithreaded pipeline.

#########################

use ExtUtils::testlib;

use Test;
BEGIN { plan tests => 2 };
use Triceps;
use Triceps::X::TestFeed qw(:all);
use Carp;
ok(1); # If we made it this far, we're ok.

use strict;

#########################
# This version of aggregation keeps updating the hourly and daily stats
# as the data comes in, on every packet (unlike xTrafficAgg.t that does that
# only at the end of the hour or day).
# It shows how each level can be split into a separate thread, to pipeline the
# computational load.

package Traffic1;

use Carp;
use Triceps::X::TestFeed qw(:all);

# Read the data and control commands from STDIN for the pipeline.
# The output is sent to the nexus "data".
# Also responsible for defining the control labels in the same nexus:
#   packet - the data
#   print - strings for printing at the end of pipeline
#   dumprq - dump requests to the elements of the pipeline
# Options inherited from Triead::start.
sub ReaderThread # (@opts)
{
	Triceps::Triead::start(
		@_,
		main => sub {
			my $opts = {};
			Triceps::Opt::parse("traffic main", $opts, {@Triceps::Triead::opts}, @_);
			my $owner = $opts->{owner};
			my $unit = $owner->unit();

			my $rtPacket = Triceps::RowType->new(
				time => "int64", # packet's timestamp, microseconds
				local_ip => "string", # string to make easier to read
				remote_ip => "string", # string to make easier to read
				local_port => "int32", 
				remote_port => "int32",
				bytes => "int32", # size of the packet
			) or confess "$!";

			my $rtPrint = Triceps::RowType->new(
				text => "string", # the text to print (including \n)
			) or confess "$!";

			my $rtDumprq = Triceps::RowType->new(
				what => "string", # identifies, what to dump
			) or confess "$!";

			my $faData = $owner->makeNexus(
				name => "data",
				labels => [
					packet => $rtPacket,
					print => $rtPrint,
					dumprq => $rtDumprq,
				],
				import => "writer",
			);

			my $lbPacket = $faData->getLabel("packet");
			my $lbPrint = $faData->getLabel("print");
			my $lbDumprq = $faData->getLabel("dumprq");

			$owner->readyReady();

			while(&readLine) {
				chomp;
				# print the input line, as a debugging exercise
				$unit->makeArrayCall($lbPrint, "OP_INSERT", "> $_\n");

				my @data = split(/,/); # starts with a command, then string opcode
				my $type = shift @data;
				if ($type eq "new") {
					$unit->makeArrayCall($lbPacket, @data);
				} elsif ($type eq "dump") {
					$unit->makeArrayCall($lbDumprq, "OP_INSERT", $data[0]);
				} else {
					$unit->makeArrayCall($lbPrint, "OP_INSERT", "Unknown command '$type'\n");
				}
				$owner->flushWriters();
			}

			{
				# drain the pipeline before shutting down
				my $ad = Triceps::AutoDrain::makeShared($owner);
				$owner->app()->shutdown();
			}
		},
	);
}

sub RUN {

Triceps::Triead::startHere(
	app => "traffic",
	thread => "print",
	main => sub {
		my $opts = {};
		Triceps::Opt::parse("traffic main", $opts, {@Triceps::Triead::opts}, @_);
		my $owner = $opts->{owner};
		my $unit = $owner->unit();

		ReaderThread(
			app => $opts->{app},
			thread => "read",
		);
if (0) {
		RawToHourlyThread(
			app => $opts->{app},
			thread => "raw_hour",
			from => "read/data",
		);
		HourlyToDailyThread(
			app => $opts->{app},
			thread => "hour_day",
			from => "raw_hour/data",
		);
		StoreDailyThread(
			app => $opts->{app},
			thread => "day",
			from => "hour_day/data",
		);
}

		$owner->markConstructed();

		my $faData = $owner->importNexus(
			from => "read/data",
			import => "reader",
		);

		$faData->getLabel("print")->makeChained("print", undef, sub {
			&send($_[1]->getRow()->get("text"));
		});
		makePrintLabel("packet", $faData->getLabel("packet"));

		$owner->readyReady();
		$owner->mainLoop(); # all driven by the reader
	},
);

};

package main;

setInputLines(
	"new,OP_INSERT,1330886011000000,1.2.3.4,5.6.7.8,2000,80,100\n",
	"new,OP_INSERT,1330886012000000,1.2.3.4,5.6.7.8,2000,80,50\n",
	"new,OP_INSERT,1330889811000000,1.2.3.4,5.6.7.8,2000,80,300\n",
	"new,OP_INSERT,1330972411000000,1.2.3.5,5.6.7.9,3000,80,200\n",
	"new,OP_INSERT,1331058811000000\n",
	"new,OP_INSERT,1331145211000000\n",
);
&Traffic1::RUN();
#print &getResultLines();
ok(&getResultLines(), 
'> new,OP_INSERT,1330886011000000,1.2.3.4,5.6.7.8,2000,80,100
data.packet OP_INSERT time="1330886011000000" local_ip="1.2.3.4" remote_ip="5.6.7.8" local_port="2000" remote_port="80" bytes="100" 
> new,OP_INSERT,1330886012000000,1.2.3.4,5.6.7.8,2000,80,50
data.packet OP_INSERT time="1330886012000000" local_ip="1.2.3.4" remote_ip="5.6.7.8" local_port="2000" remote_port="80" bytes="50" 
> new,OP_INSERT,1330889811000000,1.2.3.4,5.6.7.8,2000,80,300
data.packet OP_INSERT time="1330889811000000" local_ip="1.2.3.4" remote_ip="5.6.7.8" local_port="2000" remote_port="80" bytes="300" 
> new,OP_INSERT,1330972411000000,1.2.3.5,5.6.7.9,3000,80,200
data.packet OP_INSERT time="1330972411000000" local_ip="1.2.3.5" remote_ip="5.6.7.9" local_port="3000" remote_port="80" bytes="200" 
> new,OP_INSERT,1331058811000000
data.packet OP_INSERT time="1331058811000000" 
> new,OP_INSERT,1331145211000000
data.packet OP_INSERT time="1331145211000000" 
');
