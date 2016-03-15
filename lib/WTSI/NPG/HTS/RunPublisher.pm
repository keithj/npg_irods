package WTSI::NPG::HTS::RunPublisher;

use namespace::autoclean;
use Data::Dump qw[pp];
use English qw[-no_match_vars];
use File::Basename;
use List::AllUtils qw[any first none];
use File::Spec::Functions qw[catdir catfile splitdir];
use Moose;
use MooseX::StrictConstructor;
use Try::Tiny;

use WTSI::DNAP::Utilities::Params qw[function_params];
use WTSI::NPG::HTS::IlluminaObjFactory;
use WTSI::NPG::HTS::LIMSFactory;
use WTSI::NPG::HTS::Publisher;
use WTSI::NPG::HTS::Types qw[AlMapFileFormat];
use WTSI::NPG::iRODS::Metadata;
use WTSI::NPG::iRODS;

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::DNAP::Utilities::JSONCodec
         WTSI::NPG::HTS::Annotator
         npg_tracking::illumina::run::short_info
         npg_tracking::illumina::run::folder
       ];

with qw[npg_tracking::illumina::run::long_info];

our $VERSION = '';

# Default 
our $DEFAULT_ROOT_COLL = '/seq';
our $DEFAULT_QC_COLL   = 'qc';

# Alignment and index file suffixes
our $BAM_FILE_FORMAT   = 'bam';
our $BAM_INDEX_FORMAT  = 'bai';
our $CRAM_FILE_FORMAT  = 'cram';
our $CRAM_INDEX_FORMAT = 'crai';

# Cateories of file to be published
our $ALIGNMENT_CATEGORY = 'alignment';
our $ANCILLARY_CATEGORY = 'ancillary';
our $INDEX_CATEGORY     = 'index';
our $QC_CATEGORY        = 'qc';
# XML files do not have a category because they exist once per run,
# while all the rest exist per lane and/or plex

our @FILE_CATEGORIES = ($ALIGNMENT_CATEGORY, $ANCILLARY_CATEGORY,
                        $INDEX_CATEGORY, $QC_CATEGORY);

our $NUM_READS_JSON_PROPERTY = 'num_total_reads';

has 'irods' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::iRODS',
   required      => 1,
   documentation => 'An iRODS handle to run searches and perform updates');

has 'obj_factory' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::HTS::DataObjectFactory',
   required      => 1,
   builder       => '_build_obj_factory',
   documentation => 'A factory building data objects from files');

has 'lims_factory' =>
  (is            => 'ro',
   isa           => 'WTSI::NPG::HTS::LIMSFactory',
   required      => 1,
   documentation => 'A factory providing st:api::lims objects');

has 'file_format' =>
  (isa           => AlMapFileFormat,
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   default       => 'cram',
   documentation => 'The format of the file to be published');

has 'ancillary_formats' =>
  (isa           => 'ArrayRef',
   is            => 'ro',
   required      => 1,
   lazy          => 1,
   default       => sub {
     return [qw[bed bamcheck flagstat stats txt seqchksum]];
   },
   documentation => 'The ancillary file formats to be published');

has 'dest_collection' =>
  (isa           => 'Str',
   is            => 'ro',
   lazy          => 1,
   builder       => '_build_dest_collection',
   documentation => 'The destination collection within iRODS to store data');

has 'qc_dest_collection' =>
  (isa           => 'Str',
   is            => 'ro',
   lazy          => 1,
   builder       => '_build_qc_dest_collection',
   documentation => 'The destination collection within iRODS to store QC data');

has 'alt_process' =>
  (isa           => 'Maybe[Str]',
   is            => 'ro',
   required      => 0,
   documentation => 'Non-standard process used');

has '_path_cache' =>
  (isa           => 'HashRef',
   is            => 'ro',
   required      => 1,
   default       => sub { return {} },
   init_arg      => undef,
   documentation => 'Caches of file paths read from disk, indexed by method');

has '_json_cache' =>
  (isa           => 'HashRef',
   is            => 'ro',
   required      => 1,
   default       => sub { return {} },
   init_arg      => undef,
   documentation => 'Cache of JSON data read from disk, indexed by path');


sub BUILD {
  my ($self) = @_;

  # Use our logger to log activity in attributes.
  $self->irods->logger($self->logger);
  $self->lims_factory->logger($self->logger);
  return;
}

# The list_*_files methods are uncached. The verb in their name
# suggests activity. The corresponding methods generated here without
# the list_ prefix are caching. We are not using attributes here
# because the plex-level accessors have a position parameter.
my @CACHING_LANE_METHOD_NAMES = qw[lane_alignment_files
                                   lane_index_files
                                   lane_qc_files
                                   lane_ancillary_files];
my @CACHING_PLEX_METHOD_NAMES = qw[plex_alignment_files
                                   plex_index_files
                                   plex_qc_files
                                   plex_ancillary_files];

foreach my $method_name (@CACHING_LANE_METHOD_NAMES,
                         @CACHING_PLEX_METHOD_NAMES) {
  __PACKAGE__->meta->add_method
    ($method_name,
     sub {
       my ($self, $position) = @_;

       my $cache = $self->_path_cache;
       if (exists $cache->{$method_name}->{$position}) {
         $self->debug('Using cached result for ', __PACKAGE__,
                      "::$method_name($position)");
       }
       else {
         $self->debug('Caching result for ', __PACKAGE__,
                      "::$method_name($position)");

         my $uncached_method_name = "list_$method_name";
         $cache->{$method_name}->{$position} =
           $self->$uncached_method_name($position);
       }

       return $cache->{$method_name}->{$position};
     });
}

=head2 positions

  Arg [1]    : None

  Example    : $pub->positions
  Description: Return a sorted array of lane position numbers.
  Returntype : Array

=cut

sub positions {
  my ($self) = @_;

  return $self->lims_factory->positions($self->id_run);
}

=head2 is_plexed

  Arg [1]    : Lane position, Int.

  Example    : $pub->is_plexed($position)
  Description: Return true if the lane position contains plexed data.
  Returntype : Bool

=cut

sub is_plexed {
  my ($self, $position) = @_;

  my $pos = $self->_check_position($position);

  return -d $self->lane_archive_path($pos);
}

=head2 num_reads

  Arg [1]    : Lane position, Int.
  Arg [2]    : Tag index, Int. Required for plexed positions.

  Named args : tag_index            Tag index, Int. Required for
                                    plexed positions.
               alignment_filter     Alignment filter name. Optional.
                                    Used to request the number of reads
                                    for a particular alignment filter.

  Example    : my $num_lane_reads = $pub->num_reads($position1)
               my $num_plex_reads = $pub->num_reads($position2,
                                                    tag_index        => 1,
                                                    alignment_filter => 'phix')
  Description: Return the total number of primary, non-supplementary
               reads.
  Returntype : Int

=cut

{
  my $positional = 2;
  my @named      = qw[alignment_filter tag_index];
  my $params = function_params($positional, @named);

  sub num_reads {
    my ($self, $position) = $params->parse(@_);

    my $pos = $self->_check_position($position);

    my $qc_file;
    if ($self->is_plexed($pos)) {
      defined $params->tag_index or
        $self->logconfess('A defined tag_index argument is required');
      $qc_file = $self->_plex_qc_stats_file($pos, $params->tag_index,
                                            $params->alignment_filter);
    }
    else {
      $qc_file = $self->_lane_qc_stats_file($pos, $params->alignment_filter);
    }

    my $num_reads;
    if ($qc_file) {
      my $flag_stats = $self->_parse_json_file($qc_file);
      if ($flag_stats) {
        $num_reads = $flag_stats->{$NUM_READS_JSON_PROPERTY};
      }
    }

    return $num_reads
  }
}

sub index_format {
  my ($self) = @_;

  my $index_format;
  if ($self->file_format eq $BAM_FILE_FORMAT) {
    $index_format = $BAM_INDEX_FORMAT;
  }
  elsif ($self->file_format eq $CRAM_FILE_FORMAT) {
    $index_format = $CRAM_INDEX_FORMAT;
  }
  else {
    $self->logconfess('The index format corresponding to HTS file format ',
                      $self->file_format, ' is unknown');
  }

  return $index_format;
}

=head2 list_xml_files

  Arg [1]    : None

  Example    : $pub->list_xml_files;
  Description: Return paths of all run-level XML files for the run.
               Calling this method will access the file system.
  Returntype : ArrayRef[Str]

=cut

sub list_xml_files {
  my ($self) = @_;

  my $runfolder_path   = $self->runfolder_path;
  my $xml_file_pattern = '^(RunInfo|runParameters).xml$';

  return [$self->_list_directory($runfolder_path, $xml_file_pattern)];
}

=head2 list_lane_alignment_files

  Arg [1]    : None

  Example    : $pub->list_lane_alignment_files;
  Description: Return paths of all lane-level alignment files for the run.
               Calling this method will access the file system. For
               cached access to the list, use the lane_alignment_files
               method.
  Returntype : ArrayRef[Str]

=cut

sub list_lane_alignment_files {
  my ($self, $position) = @_;

  my $pos;
  if (defined $position) {
    $pos = $self->_check_position($position);
  }

  my $positions_pattern = $self->_positions_pattern($pos);
  my $lane_file_pattern = sprintf '^%d_%s.*[.]%s$',
    $self->id_run, $positions_pattern, $self->file_format;

  return [$self->_list_directory($self->archive_path, $lane_file_pattern)];
}

=head2 list_plex_alignment_files

  Arg [1]    : Lane position, Int.

  Example    : $pub->list_plex_alignment_files($position);
  Description: Return paths of all plex-level alignment files for the
               given lane. Calling this method will access the file
               system. For cached access to the list, use the
               plex_alignment_files method.
  Returntype : ArrayRef[Str]

=cut

sub list_plex_alignment_files {
  my ($self, $position) = @_;

  my $pos = $self->_check_position($position);

  my $plex_file_pattern = sprintf '^%d_%d.*[.]%s$',
    $self->id_run, $pos, $self->file_format;

  return [$self->_list_directory($self->lane_archive_path($pos),
                                 $plex_file_pattern)];
}

=head2 list_lane_index_files

  Arg [1]    : None

  Example    : $pub->list_lane_index_files;
  Description: Return paths of all lane-level index files for the run.
               Calling this method will access the file system. For
               cached access to the list, use the lane_index_files
               method.
  Returntype : ArrayRef[Str]

=cut

sub list_lane_index_files {
  my ($self, $position) = @_;

  my $pos;
  if (defined $position) {
    $pos = $self->_check_position($position);
  }

  my $file_format       = $self->file_format;
  my $positions_pattern = $self->_positions_pattern($pos);

  my $lane_file_pattern;
  if ($file_format eq $BAM_FILE_FORMAT) {
    $lane_file_pattern = sprintf '^%d_%s.*[.]%s$',
      $self->id_run, $positions_pattern, $self->index_format;
  }
  elsif ($file_format eq $CRAM_FILE_FORMAT) {
    $lane_file_pattern = sprintf '^%d_%s.*[.]%s\.%s$',
      $self->id_run, $positions_pattern, $file_format, $self->index_format;
  }
  else {
    $self->logconfess("Invalid HTS file format for indexing '$file_format'");
  }

  return [$self->_list_directory($self->archive_path, $lane_file_pattern)];
}

=head2 list_plex_index_files

  Arg [1]    : Lane position, Int.

  Example    : $pub->list_plex_index_files($position);
  Description: Return paths of all plex-level index files for the
               given lane. Calling this method will access the file
               system. For cached access to the list, use the
               plex_index_files method.
  Returntype : ArrayRef[Str]

=cut

sub list_plex_index_files {
  my ($self, $position) = @_;

  my $pos = $self->_check_position($position);

  my $file_format = $self->file_format;

  my $plex_file_pattern;
  if ($file_format eq $BAM_FILE_FORMAT) {
    $plex_file_pattern = sprintf '^%d_%d.*[.]%s$',
      $self->id_run, $pos, $self->index_format;
  }
  elsif ($file_format eq $CRAM_FILE_FORMAT) {
    $plex_file_pattern = sprintf '^%d_%d.*[.]%s[.]%s$',
      $self->id_run, $pos, $file_format, $self->index_format;
  }
  else {
    $self->logconfess("Invalid HTS file format for indexing '$file_format'");
  }

  return [$self->_list_directory($self->lane_archive_path($pos),
                                 $plex_file_pattern)];
}

=head2 list_lane_qc_files

  Arg [1]    : None

  Example    : $pub->list_qc_alignment_files;
  Description: Return paths of all lane-level qc files for the run.
               Calling this method will access the file system. For
               cached access to the list, use the lane_qc_files
               method.
  Returntype : ArrayRef[Str]

=cut

sub list_lane_qc_files {
  my ($self, $position) = @_;

  my $pos;
  if (defined $position) {
    $pos = $self->_check_position($position);
  }

  my $file_format       = 'json';
  my $positions_pattern = $self->_positions_pattern($pos);
  my $lane_file_pattern = sprintf '^%d_%s.*[.]%s$',
    $self->id_run, $positions_pattern, $file_format;

  return [$self->_list_directory($self->qc_path, $lane_file_pattern)];
}

=head2 list_plex_qc_files

  Arg [1]    : Lane position, Int.

  Example    : $pub->list_plex_qc_files($position);
  Description: Return paths of all plex-level qc files for the
               given lane. Calling this method will access the file
               system. For cached access to the list, use the
               plex_qc_files method.
  Returntype : ArrayRef[Str]

=cut

sub list_plex_qc_files {
  my ($self, $position) = @_;

  my $pos = $self->_check_position($position);

  my $file_format       = 'json';
  my $plex_file_pattern = sprintf '^%d_%d.*[.]%s$',
    $self->id_run, $position, $file_format;

  return [$self->_list_directory($self->lane_qc_path($pos),
                                 $plex_file_pattern)];
}

=head2 list_lane_ancillary_files

  Arg [1]    : Lane position, Int.

  Example    : $pub->list_lane_ancillary_files($position);
  Description: Return paths of all lane-level ancillary files for the
               given lane. Calling this method will access the file
               system. For cached access to the list, use the
               lane_ancillary_files method.
  Returntype : ArrayRef[Str]

=cut

sub list_lane_ancillary_files {
  my ($self, $position) = @_;

  my $pos;
  if (defined $position) {
    $pos = $self->_check_position($position);
  }

  my $positions_pattern = $self->_positions_pattern($pos);
  my $suffix_pattern    = sprintf '(%s)',
    join q[|], @{$self->ancillary_formats};
  my $lane_file_pattern = sprintf '^%d_%s.*[.]%s$',
    $self->id_run, $positions_pattern, $suffix_pattern;

  my @file_list = $self->_list_directory($self->archive_path,
                                         $lane_file_pattern);
  # The file pattern match is deliberately kept simple. The downside
  # is that it matches one file that we do not want.
  @file_list = grep { ! m{markdups_metrics}msx } @file_list;

  return \@file_list;
}

sub list_plex_ancillary_files {
  my ($self, $position) = @_;

  my $pos = $self->_check_position($position);

  my $suffix_pattern    = sprintf '(%s)',
    join q[|], @{$self->ancillary_formats};
  my $plex_file_pattern = sprintf '^%d_%d.*[.]%s$',
    $self->id_run, $pos, $suffix_pattern;

  my @file_list = $self->_list_directory($self->lane_archive_path($pos),
                                         $plex_file_pattern);
  # The file pattern match is deliberately kept simple. The downside
  # is that it matches one file that we do not want.
  @file_list = grep { ! m{markdups_metrics}msx } @file_list;

  return \@file_list;
}

=head2 publish_files

  Arg [1]    : None

  Named args : positions            ArrayRef[Int]. Optional.
               with_spiked_control  Bool. Optional

  Example    : my $num_published = $pub->publish_alignment_files
  Description: Publish all files (lane- or plex-level) to iRODS. If the
               positions argument is supplied, only those positions will be
               published. The default is to publish all positions. Return
               the number of files, the number published and the number of
               errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[positions with_spiked_control];
  my $params = function_params($positional, @named);

  sub publish_files {
    my ($self) = $params->parse(@_);

    my $positions = $params->positions || [$self->positions];

    # XML files do not have a lane position; they belong to the entire
    # run
    my ($num_files, $num_processed, $num_errors) = $self->publish_xml_files;

    foreach my $category (@FILE_CATEGORIES) {
      my ($nf, $np, $ne) =
        $self->_publish_file_category($category,
                                      $positions,
                                      $params->with_spiked_control);
      $num_files     += $nf;
      $num_processed += $np;
      $num_errors    += $ne;
    }

    return ($num_files, $num_processed, $num_errors);
  }
}

=head2 publish_xml_files

  Arg [1]    : None

  Example    : my $num_published = $pub->publish_alignment_files
  Description: Publish alignment files (lane- or plex-level) to
               iRODS. Return the number of files, the number published
               and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_xml_files {
  my ($self) = @_;

  return $self->_publish_support_files($self->list_xml_files,
                                       $self->dest_collection);
}

=head2 publish_alignment_files

  Arg [1]    : None

  Named args : positions            ArrayRef[Int]. Optional.
               with_spiked_control  Bool. Optional

  Example    : my $num_published = $pub->publish_alignment_files
  Description: Publish alignment files (lane- or plex-level) to
               iRODS. If the positions argument is supplied, only those
               positions will be published. The default is to publish all
               positions. Return the number of files, the number published
               and the number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[positions with_spiked_control];
  my $params = function_params($positional, @named);

  sub publish_alignment_files {
    my ($self) = $params->parse(@_);

    my $positions = $params->positions || [$self->positions];

    return $self->_publish_file_category($ALIGNMENT_CATEGORY,
                                         $positions,
                                         $params->with_spiked_control);
  }
}

=head2 publish_lane_alignment_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_lane_alignment_files(8)
  Description: Publish lane-level alignment files to iRODS.
               Return the number of files, the number published and
               the number of errors.
  Returntype : Array[Int]

=cut

sub publish_lane_alignment_files {
  my ($self, $position, $with_spiked_control) = @_;

  my $pos = $self->_check_position($position);

  my $id_run = $self->id_run;
  my $num_files;
  my $num_processed;
  my $num_errors;

  if (not $self->is_plexed($pos)) {
    ($num_files, $num_processed, $num_errors) =
      $self->_publish_alignment_files($pos,
                                      $self->lane_alignment_files($pos),
                                      $self->dest_collection,
                                      $with_spiked_control);
    $self->info("Published $num_processed / $num_files lane-level ",
                "alignment files in run '$id_run'");
  }
  else {
    $self->logconfess("Attempted to publish position '$pos' plex-level ",
                      "alignment files in run '$id_run'; ",
                      'the position is not plexed');
  }

  return ($num_files, $num_processed, $num_errors);
}

=head2 publish_plex_alignment_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_plex_alignment_files(8)
  Description: Publish plex-level alignment files in the
               specified lane to iRODS.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_plex_alignment_files {
  my ($self, $position, $with_spiked_control) = @_;

  my $pos = $self->_check_position($position);

  my $id_run = $self->id_run;
  my $num_files;
  my $num_processed;
  my $num_errors;

  if ($self->is_plexed($pos)) {
    ($num_files, $num_processed, $num_errors) =
      $self->_publish_alignment_files($pos,
                                      $self->plex_alignment_files($position),
                                      $self->dest_collection,
                                      $with_spiked_control);
    $self->info("Published $num_processed / $num_files plex-level ",
                "alignment files in run '$id_run' position '$pos'");
  }
  else {
    $self->logconfess("Attempted to publish position '$pos' lane-level ",
                      "alignment files in run '$id_run'; ",
                      'the position is plexed');
  }

  return ($num_files, $num_processed, $num_errors);
}

=head2 publish_index_files

  Arg [1]    : None

  Named args : positions            ArrayRef[Int]. Optional.
               with_spiked_control  Bool. Optional

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_index_files
  Description: Publish index files (lane- or plex-level) to
               iRODS.  If the positions argument is supplied, only those
               positions will be published. The default is to publish all
               positions.  Return the number of files, the number published
               and the number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[positions with_spiked_control];
  my $params = function_params($positional, @named);

  sub publish_index_files {
    my ($self) = $params->parse(@_);

    my $positions = $params->positions || [$self->positions];

    return $self->_publish_file_category($INDEX_CATEGORY,
                                         $positions,
                                         $params->with_spiked_control);
  }
}

=head2 publish_lane_index_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_plex_ancillary_files(8)
  Description: Publish lane-level ancillary files to iRODS.
               Return the number of files, the number published and
               the number of errors.
  Returntype : Array[Int]

=cut

sub publish_lane_index_files {
  my ($self, $position, $with_spiked_control) = @_;

  return $self->_publish_lane_support_files($position,
                                            $self->lane_index_files($position),
                                            $self->dest_collection,
                                            $INDEX_CATEGORY,
                                            $with_spiked_control);
}

=head2 publish_plex_index_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_plex_ancillary_files(8)
  Description: Publish plex-level ancillary files to iRODS.
               Return the number of files, the number published and
               the number of errors.
  Returntype : Array[Int]

=cut

sub publish_plex_index_files {
  my ($self, $position, $with_spiked_control) = @_;

  return  $self->_publish_plex_support_files($position,
                                             $self->plex_index_files($position),
                                             $self->dest_collection,
                                             $INDEX_CATEGORY,
                                             $with_spiked_control);
}

=head2 publish_ancillary_files

  Arg [1]    : None

  Named args : positions            ArrayRef[Int]. Optional.
               with_spiked_control  Bool. Optional

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_ancillary_files
  Description: Publish ancillary files (lane- or plex-level) to
               iRODS.  If the positions argument is supplied, only those
               positions will be published. The default is to publish all
               positions.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional  = 1;
  my @named       = qw[positions with_spiked_control];
  my $params = function_params($positional, @named);

  sub publish_ancillary_files {
    my ($self) = $params->parse(@_);

    my $positions = $params->positions || [$self->positions];

    return $self->_publish_file_category($ANCILLARY_CATEGORY,
                                         $positions,
                                         $params->with_spiked_control);
  }
}

=head2 publish_lane_ancillary_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_lane_ancillary_files(8)
  Description: Publish lane-level ancillary files in the
               specified lane to iRODS.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_lane_ancillary_files {
  my ($self, $position, $with_spiked_control) = @_;

  return $self->_publish_lane_support_files
    ($position,
     $self->lane_ancillary_files($position),
     $self->dest_collection,
     $ANCILLARY_CATEGORY,
     $with_spiked_control);
}

=head2 publish_plex_ancillary_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_plex_ancillary_files(8)
  Description: Publish plex-level ancillary files in the
               specified lane to iRODS.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_plex_ancillary_files {
  my ($self, $position, $with_spiked_control) = @_;

  return $self->_publish_plex_support_files
    ($position,
     $self->plex_ancillary_files($position),
     $self->dest_collection,
     $ANCILLARY_CATEGORY,
     $with_spiked_control);
}

=head2 publish_qc_files

  Arg [1]    : None

  Named args : positions            ArrayRef[Int]. Optional.
               with_spiked_control  Bool. Optional

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_qc_files
  Description: Publish qc files (lane- or plex-level) to
               iRODS.  If the positions argument is supplied, only those
               positions will be published.  The default is to publish all
               positions.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

{
  my $positional = 1;
  my @named      = qw[positions with_spiked_control];
  my $params = function_params($positional, @named);

  sub publish_qc_files {
    my ($self) = $params->parse(@_);

    my $positions = $params->positions || [$self->positions];

    return $self->_publish_file_category($QC_CATEGORY,
                                         $positions,
                                         $params->with_spiked_control);
  }
}

=head2 publish_lane_qc_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_lane_qc_files(8)
  Description: Publish lane-level QC files in the
               specified lane to iRODS.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_lane_qc_files {
  my ($self, $position, $with_spiked_control) = @_;

  return $self->_publish_lane_support_files($position,
                                            $self->lane_qc_files($position),
                                            $self->qc_dest_collection,
                                            $QC_CATEGORY,
                                            $with_spiked_control);
}

=head2 publish_plex_qc_files

  Arg [1]    : Lane position, Int.
  Arg [2]    : HTS data has spiked control, Bool. Optional.

  Example    : my ($num_files, $num_published, $num_errors) =
                 $pub->publish_plex_qc_files(8)
  Description: Publish plex-level QC files in the
               specified lane to iRODS.  Return the number of files,
               the number published and the number of errors.
  Returntype : Array[Int]

=cut

sub publish_plex_qc_files {
  my ($self, $position, $with_spiked_control) = @_;

  return $self->_publish_plex_support_files($position,
                                            $self->plex_qc_files($position),
                                            $self->qc_dest_collection,
                                            $QC_CATEGORY,
                                            $with_spiked_control);
}

# Check that a position argument is given and valid
sub _check_position {
  my ($self, $position) = @_;

  defined $position or
    $self->logconfess('A defined position argument is required');
  any { $position } $self->positions or
    $self->logconfess("Invalid position argument '$position'");

  return $position;
}

# Create a pattern to match file of one position, or all positions
sub _positions_pattern {
  my ($self, $position) = @_;

  my $pattern;
  if (defined $position) {
    $pattern = $self->_check_position($position);
  }
  else {
    $pattern = sprintf '[%s]', join q[], $self->positions;
  }

  return $pattern;
}

# A dispatcher to call the correct method for a given file category
# and lane plex state
sub _publish_file_category {
  my ($self, $category, $positions, $with_spiked_control) = @_;

  defined $positions or
    $self->logconfess('A defined positions argument is required');
  ref $positions eq 'ARRAY' or
    $self->logconfess('The positions argument is required to be an ArrayRef');

  defined $category or
    $self->logconfess('A defined category argument is required');
  any { $category eq $_ } @FILE_CATEGORIES or
    $self->logconfess("Unknown file category '$category'");

  my $lane_method = sprintf 'publish_lane_%s_files', $category;
  my $plex_method = sprintf 'publish_plex_%s_files', $category;

  my $num_files;
  my $num_processed;
  my $num_errors;

  $self->info("Publishing $category files for positions: ", pp($positions));

  foreach my $position (@{$positions}) {
    my $pos = $self->_check_position($position);

    my ($nf, $np, $ne);
    if ($self->is_plexed($pos)) {
      ($nf, $np, $ne) = $self->$plex_method($pos, $with_spiked_control);
    }
    else {
      ($nf, $np, $ne) = $self->$lane_method($pos, $with_spiked_control);
    }

    $num_files     += $nf;
    $num_processed += $np;
    $num_errors    += $ne;
  }

  return ($num_files, $num_processed, $num_errors);
}

# Backend alignment file publisher
sub _publish_alignment_files {
  my ($self, $position, $files, $dest_coll, $with_spiked_control) = @_;

  my $pos = $self->_check_position($position);

  my $publisher = WTSI::NPG::HTS::Publisher->new(irods  => $self->irods,
                                                 logger => $self->logger);

  my $num_files     = scalar @{$files};
  my $num_processed = 0;
  my $num_errors    = 0;
  foreach my $file (@{$files}) {
    my $dest = q[];

    try {
      $num_processed++;

      # Currently these determine their own id_run, position, plex and
      # alignment_filter by parsing their own file name. We should
      # really pass this information to the factory
      my ($filename, $directories, $suffix) = fileparse($file);
      my $obj = $self->obj_factory->make_data_object
        (catfile($dest_coll, $filename));
      $dest = $obj->str;
      $dest = $publisher->publish($file, $dest);

      my $num_reads = $self->num_reads
        ($pos,
         alignment_filter => $obj->alignment_filter,
         tag_index        => $obj->tag_index);

      my @pri = $self->make_primary_metadata
        ($self->id_run, $pos, $num_reads,
         tag_index        => $obj->tag_index,
         is_paired_read   => $self->is_paired_read,
         is_aligned       => $obj->is_aligned,
         reference        => $obj->reference,
         alignment_filter => $obj->alignment_filter,
         alt_process      => $self->alt_process);
      $self->debug("Created primary metadata AVUs for '$dest': ", pp(\@pri));
      $obj->set_primary_metadata(@pri);

      my @sec = $self->make_secondary_metadata
        ($self->lims_factory, $self->id_run, $pos,
         tag_index           => $obj->tag_index,
         with_spiked_control => $with_spiked_control);
      $self->debug("Created secondary metadata AVUs for '$dest': ", pp(\@sec));
      $obj->update_secondary_metadata(@sec);

      $self->info("Published '$dest' [$num_processed / $num_files]");
    } catch {
      $num_errors++;

      ## no critic (RegularExpressions::RequireDotMatchAnything)
      my ($msg) = m{^(.*)$}mx;
      ## use critic
      $self->error("Failed to publish '$file' to '$dest' ",
                   "[$num_processed / $num_files]: ", $msg);
    };
  }

  if ($num_errors > 0) {
    $self->error("Encountered errors on $num_errors / ",
                 "$num_processed alignment files processed");
  }

  return ($num_files, $num_processed, $num_errors);
}

# Backend ancillary, index and qc file publisher for lane-level positions
## no critic (Subroutines::ProhibitManyArgs)
sub _publish_lane_support_files {
  my ($self, $position, $files, $dest_collection, $description,
      $with_spiked_control) = @_;

  my $pos = $self->_check_position($position);

  my $id_run = $self->id_run;
  my $num_files;
  my $num_processed;
  my $num_errors;

  if (not $self->is_plexed($pos)) {
    ($num_files, $num_processed, $num_errors) =
      $self->_publish_support_files($files, $dest_collection,
                                    $with_spiked_control);
    $self->info("Published $num_processed / $num_files lane-level ",
                "$description files in run '$id_run' position '$pos'");
  }
  else {
    $self->logconfess("Attempted to publish position '$pos' lane-level ",
                      "$description files in run '$id_run'; ",
                      'the position is plexed');
  }

  return ($num_files, $num_processed, $num_errors);
}
## use critic

# Backend ancillary, index and qc file publisher for plex-level positions
## no critic (Subroutines::ProhibitManyArgs)
sub _publish_plex_support_files {
  my ($self, $position, $files, $dest_collection, $description,
      $with_spiked_control) = @_;

  my $pos = $self->_check_position($position);

  my $id_run = $self->id_run;
  my $num_files;
  my $num_processed;
  my $num_errors;

  if ($self->is_plexed($pos)) {
    ($num_files, $num_processed, $num_errors) =
      $self->_publish_support_files($files, $dest_collection,
                                    $with_spiked_control);
    $self->info("Published $num_processed / $num_files plex-level ",
                "$description files in run '$id_run' position '$pos'");
  }
  else {
    $self->logconfess("Attempted to publish position '$pos' lane-level ",
                      "$description files in run '$id_run'; ",
                      'the position is not plexed');
  }

  return ($num_files, $num_processed, $num_errors);
}
## use critic

# Backend publisher for qc, index and ancillary files
sub _publish_support_files {
  my ($self, $files, $dest_coll, $with_spiked_control) = @_;

  defined $files or
    $self->logconfess('A defined files argument is required');
  ref $files eq 'ARRAY' or
    $self->logconfess('The files argument must be an ArrayRef');
  defined $dest_coll or
    $self->logconfess('A defined dest_coll argument is required');

  my $publisher = WTSI::NPG::HTS::Publisher->new(irods  => $self->irods,
                                                 logger => $self->logger);

  my $num_files     = scalar @{$files};
  my $num_processed = 0;
  my $num_errors    = 0;
  foreach my $file (@{$files}) {
    my $dest = q[];

    try {
      $num_processed++;
      my ($filename, $directories, $suffix) = fileparse($file);
      my $obj = $self->obj_factory->make_data_object
        (catfile($dest_coll, $filename), id_run => $self->id_run);
      $dest = $obj->str;
      $dest = $publisher->publish($file, $dest);

      my @primary_avus = ($self->make_avu($ID_RUN, $self->id_run));
      if (defined $self->alt_process) {
        push @primary_avus, $self->make_alt_metadata($self->alt_process);
      }
      $obj->set_primary_metadata(@primary_avus);

      my $lims = $self->lims_factory->make_lims($obj->id_run,
                                                $obj->position,
                                                $obj->tag_index);
      # Sufficient study metadata to set their permissions, if they are
      # restricted.
      my @secondary_avus = $self->make_study_id_metadata
        ($lims, $with_spiked_control);
      $obj->update_secondary_metadata(@secondary_avus);

      $self->info("Published '$dest' [$num_processed / $num_files]");
    } catch {
      $num_errors++;

      ## no critic (RegularExpressions::RequireDotMatchAnything)
      my ($msg) = m{^(.*)$}mx;
      ## use critic
      $self->error("Failed to publish '$file' to '$dest' ",
                   "[$num_processed / $num_files]: ", $msg);
    };
  }

  if ($num_errors > 0) {
    $self->error("Encountered errors on $num_errors / ",
                 "$num_processed files processed");
  }

  return ($num_files, $num_processed, $num_errors);
}

# We are required by npg_tracking::illumina::run::short_info to
# implment this method
sub _build_run_folder {
  my ($self) = @_;

  if (! ($self->_given_path or $self->has_id_run or $self->has_name)){
    $self->logconfess('The run folder cannot be determined because ',
                      'it was not supplied to the constructor and ',
                      'no path, id_run or run name were available, ',
                      'from which it could be inferred');
  }

  return first { $_ ne q[] } reverse splitdir($self->runfolder_path);
}

sub _build_dest_collection  {
  my ($self) = @_;

  my @colls = ($DEFAULT_ROOT_COLL, $self->id_run);
  if (defined $self->alt_process) {
    push @colls, $self->alt_process
  }

  return catdir(@colls);
}

sub _build_qc_dest_collection  {
  my ($self) = @_;

  return catdir($self->dest_collection, $DEFAULT_QC_COLL);
}

sub _build_obj_factory {
  my ($self) = @_;

  return WTSI::NPG::HTS::IlluminaObjFactory->new(irods  => $self->irods,
                                                 logger => $self->logger);
}

# Return a sorted array of file paths, filtered by a regex.
sub _list_directory {
  my ($self, $path, $filter_pattern) = @_;

  $self->debug("Finding files in '$path' matching pattern '$filter_pattern'");

  my @file_list;
  opendir my $dh, $path or $self->logcroak("Failed to opendir '$path': $!");
  @file_list = grep { m{$filter_pattern}msx } readdir $dh;
  closedir $dh;

  @file_list = sort map { catfile($path, $_) } @file_list;

  $self->debug("Found files in '$path' matching pattern '$filter_pattern': ",
               pp(\@file_list));

  return @file_list;
}

sub _lane_qc_stats_file {
  my ($self, $position, $alignment_filter) = @_;

  my $af_suffix = $alignment_filter ? "_$alignment_filter" : q[];

  my $id_run = $self->id_run;
  my $qc_file_pattern = sprintf '%s_%d%s.bam_flagstats.json$',
    $id_run, $position, $af_suffix;

  my @files = grep { m{$qc_file_pattern}msx }
    @{$self->list_lane_qc_files($position)};
  my $num_files = scalar @files;

  if ($num_files != 1) {
    $self->logcroak("Found $num_files QC files for id_run: $id_run, ",
                    "position: $position; ", pp(\@files));
  }

  return shift @files;
}

sub _plex_qc_stats_file {
  my ($self, $position, $tag_index, $alignment_filter) = @_;

  my $af_suffix = $alignment_filter ? "_$alignment_filter" : q[];

  my $id_run = $self->id_run;
  my $qc_file_pattern = sprintf '%s_%d\#%d%s.bam_flagstats.json$',
    $id_run, $position, $tag_index, $af_suffix;

  my @files = grep { m{$qc_file_pattern}msx }
    @{$self->list_plex_qc_files($position)};
  my $num_files = scalar @files;

  if ($num_files != 1) {
    $self->logcroak("Found $num_files QC files for id_run: $id_run, ",
                    "position: $position, tag_index: $tag_index; ",
                    pp(\@files));
  }

  return shift @files;
}

sub _parse_json_file {
  my ($self, $file) = @_;

  if (exists $self->_json_cache->{$file}) {
    $self->debug("Returning cached JSON value for '$file'");
  }
  else {
    local $INPUT_RECORD_SEPARATOR = undef;

    $self->debug("Parsing JSON value from '$file'");

    open my $fh, '<', $file or
      $self->error("Failed to open '$file' for reading: ", $ERRNO);
    my $octets = <$fh>;
    close $fh or $self->warn("Failed to close '$file'");

    my $json = Encode::decode('UTF-8', $octets, Encode::FB_CROAK);
    $self->_json_cache->{$file} = $self->decode($json);
  }

  return $self->_json_cache->{$file};
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::RunPublisher

=head1 DESCRIPTION

Publishes alignment, QC and ancillary files to iRODS, adds metadata and
sets permissions.

An instance of RunPublisher is responsible for copying Illumina
sequencing data from the instrument run folder to a collection in
iRODS for a single, specific run, in a single output format (e.g. BAM,
CRAM).

Data files are divided into four categories:

 - alignment files; the sequencing reads in BAM or CRAM format.
 - alignment index files; indices in the relevant format
 - ancillary files; files containing information about the run
 - QC JSON files; JSON files containing information about the run

A RunPublisher provides methods to list the complement of these
categories and to copy ("publish") them. Each of these list or publish
operations may be restricted to a specific instrument lane position.

As part of the copying process, metadata are added to, or updated on,
the files in iRODS. Following the metadata update, access permissions
are set. The information to do both of these operations is provided by
an instance of st::api::lims.

If a run is published multiple times to the same destination
collection, the following take place:

 - the RunPublisher checks local (run folder) file checksums against
   remote (iRODS) checksums and will not make unnecessary updates

 - if a local file has changed, the copy in iRODS will be overwritten
   and additional metadata indicating the time of the update will be
   added

 - the RunPublisher will proceed to make metadata and permissions
   changes to synchronise with the metadata supplied by st::api::lims,
   even if no files have been modified

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