#!/usr/bin/env perl

use strict;
use warnings;
use File::Basename;
use FindBin qw[$Bin];
use lib (-d "$Bin/../lib/perl5" ? "$Bin/../lib/perl5" : "$Bin/../lib");

use Data::Dump qw[pp];
use Getopt::Long;
use List::AllUtils qw[uniq];
use Log::Log4perl;
use Log::Log4perl::Level;
use Pod::Usage;

use WTSI::DNAP::Warehouse::Schema;
use WTSI::NPG::DriRODS;
use WTSI::NPG::HTS::LIMSFactory;
use WTSI::NPG::HTS::MetaUpdater;
use WTSI::NPG::iRODS::Metadata qw[
                                   $FILE_TYPE
                                   $ID_RUN
                                   $POSITION
                                   $TAG_INDEX
                                 ];
use WTSI::NPG::iRODS;

our $VERSION = '';
our $DEFAULT_ZONE = 'seq';

my $embedded_conf = << 'LOGCONF';
   log4perl.logger                = ERROR, A1

   log4perl.appender.A1           = Log::Log4perl::Appender::Screen
   log4perl.appender.A1.utf8      = 1
   log4perl.appender.A1.layout    = Log::Log4perl::Layout::PatternLayout
   log4perl.appender.A1.layout.ConversionPattern = %d %p %m %n
LOGCONF

my $debug;
my $dry_run = 1;
my @id_run;
my $lane;
my $log4perl_config;
my $max_id_run;
my $min_id_run;
my $stdio;
my $tag_index;
my $verbose;
my $zone;

GetOptions('debug'                 => \$debug,
           'dry-run|dry_run!'      => \$dry_run,
           'help'                  => sub { pod2usage(-verbose => 2,
                                                      -exitval => 0) },
           'lane=i'                => \$lane,
           'logconf=s'             => \$log4perl_config,
           'max-run|max_run=i'     => \$max_id_run,
           'min-run|min_run=i'     => \$min_id_run,
           'run=i'                 => \@id_run,
           'tag-index|tag_index=i' => \$tag_index,
           'verbose'               => \$verbose,
           'zone=s',               => \$zone,
           q[]                     => \$stdio);

# Process CLI arguments
if ($log4perl_config) {
  Log::Log4perl::init($log4perl_config);
}
else {
  Log::Log4perl::init(\$embedded_conf);
}

my $log = Log::Log4perl->get_logger(q[]);
if ($verbose or ($dry_run and not $debug)) {
  $log->level($INFO);
}
elsif ($debug) {
  $log->level($DEBUG);
}

if ((defined $max_id_run and not defined $min_id_run) ||
    (defined $min_id_run and not defined $max_id_run)) {
  my $msg = 'When used, the --max-run or --min-run options must be ' .
            'used together';
  pod2usage(-msg     => $msg,
            -exitval => 2);
}
if ((defined $max_id_run and defined $min_id_run) and
    ($max_id_run < $min_id_run)) {
  my $msg = "The --max-run value ($max_id_run) must be >= ".
            "the --min-run value ($min_id_run)";
  pod2usage(-msg     => $msg,
            -exitval => 2);
}

if (defined $max_id_run and defined $min_id_run) {
  push @id_run, $min_id_run .. $max_id_run;
}

@id_run = uniq sort @id_run;

$zone ||= $DEFAULT_ZONE;

# Setup iRODS
my $irods;
if ($dry_run) {
  $irods = WTSI::NPG::DriRODS->new(logger => $log);
}
else {
  $irods = WTSI::NPG::iRODS->new(logger => $log);
}

# Find data objects
my @data_objs;
if ($stdio) {
  binmode \*STDIN, 'encoding(UTF-8)';

  $log->info('Reading iRODS paths from STDIN');
  while (my $line = <>) {
    chomp $line;
    push @data_objs, $line;
  }
}
else {
  # Range queries in iRODS are so slow that we have to do lots of
  # per-run queries
  foreach my $id_run (@id_run) {
    my @query = _make_run_query($id_run, $lane, $tag_index);
    $log->info('iRODS query: ', pp(\@query));
    push @data_objs, $irods->find_objects_by_meta("/$zone", @query);
  }

  my @collections = _parse_run_collections(@data_objs);
  $log->info(pp(\@collections));

  my $recurse = 1;
  foreach my $collection (@collections) {
    my ($objs, $colls) = $irods->list_collection($collection, $recurse);
    push @data_objs, @{$objs};
  }
}

@data_objs = uniq sort @data_objs;
$log->info('Processing ', scalar @data_objs, ' data objects');

# Update metadata
my $num_updated = 0;

if (@data_objs) {
  my $wh_schema = WTSI::DNAP::Warehouse::Schema->connect;
  my $lims_factory = WTSI::NPG::HTS::LIMSFactory->new
    (mlwh_schema => $wh_schema);

  $num_updated = WTSI::NPG::HTS::MetaUpdater->new
    (irods        => $irods,
     lims_factory => $lims_factory)->update_secondary_metadata(\@data_objs);
}

$log->info("Updated metadata on $num_updated files");

sub _make_run_query {
  my ($q_id_run, $q_position, $q_tag_index) = @_;

  my @query = ([$FILE_TYPE => '%am', 'like']);
  if ($q_id_run) {
    push @query, [$ID_RUN => $q_id_run];
  }
  if ($q_position) {
    push @query, [$POSITION => $q_position];
  }
  if (defined $q_tag_index) {
    push @query, [$TAG_INDEX => $q_tag_index];
  }

  return @query;
}

sub _parse_run_collections {
  my (@paths) = @_;

  my @collections;
  foreach my $path (@paths) {
    my ($objname, $collection, $suffix) = fileparse($path);
    push @collections, $collection;
  }

  return uniq @collections;
}

__END__

=head1 NAME

npg_update_hts_metadata

=head1 SYNOPSIS

npg_update_hts_metadata [--dry-run] [--lane position] [--logconf file]
  --min-run id_run --max-run id_run | --run id_run [--tag-index i]
  [--verbose] [--zone name]

Options:

  --debug       Enable debug level logging. Optional, defaults to false.
  --dry-run
  --dry_run     Enable dry-run mode. Propose metadata changes, but do not
                perform them. Optional, defaults to true.
  --help        Display help.
  --lane        The sequencing lane/position to update. Optional.
  --logconf     A log4perl configuration file. Optional.
  --max-run
  --max_run     The upper limit of a run number range to update. Optional.
  --min-run
  --min_run     The lower limit of a run number range to update. Optional.
  --run         A specific run to update. May be given multiple times to
                specify multiple runs. If used in conjunction with --min-run
                and --max-run, the union of the two sets of runs will be
                updated.
  --tag-index
  --tag_index   A tag index within a run to update. Optional.
  --verbose     Print messages while processing. Optional.
  --zone        The iRODS zone in which to work. Optional, defaults to 'seq'.
  -             Read iRODS paths from STDIN instead of finding them by their
                run, lane and tag index.

=head1 DESCRIPTION

This script updates secondary metadata (i.e. LIMS-derived metadata,
not primary experimental metadata) on CRAM and BAM files in iRODS. The
files may be specified by run (optionally restricted further by lane
and tag index) in which case either a specific run or run range must
be given. Alternatively a list of iRODS paths may be piped to
STDIN.

In dry run mode, the proposed metadata changes will be written as INFO
notices to the log.

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2015, 2016 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut