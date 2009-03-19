package JAC::OCS::Config::TCS;

=head1 NAME

JAC::OCS::Config::TCS - Parse and modify TCS TOML configuration information

=head1 SYNOPSIS

  use JAC::OCS::Config::TCS;

  $cfg = new JAC::OCS::Config::TCS( File => 'tcs.xml');
  $cfg = new JAC::OCS::Config::TCS( XML => $xml );
  $cfg = new JAC::OCS::Config::TCS( DOM => $dom );

  $base  = $cfg->getTarget;
  $guide = $cfg->getCoords( 'GUIDE' );

=head1 DESCRIPTION

This class can be used to parse and modify the telescope configuration
information present in either the C<TCS_CONFIG> element of a
standalone configuration file, or the C<SpTelescopeObsComp> element of
a standard TOML file.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;
use Scalar::Util qw/ blessed /;
use Astro::SLA;
use Astro::Coords;
use Astro::Coords::Offset;
use Data::Dumper;

use JAC::OCS::Config::Error qw| :try |;
use JAC::OCS::Config::Helper qw/ check_class_fatal /;
use JAC::OCS::Config::XMLHelper qw| find_children find_attr
                                    indent_xml_string
                                  |;
use JAC::OCS::Config::TCS::Generic qw| find_pa pa_to_xml offset_to_xml |;

use JAC::OCS::Config::TCS::BASE;
use JAC::OCS::Config::TCS::obsArea;
use JAC::OCS::Config::TCS::Secondary;

use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = 1.0;

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new TCS configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::TCS( File => $file );
  $cfg = new JAC::OCS::Config::TCS( XML => $xml );
  $cfg = new JAC::OCS::Config::TCS( DOM => $dom );

The constructor will locate the TCS configuration in either a
SpTelescopeObsComp element (the element used in the TOML XML dialect
to represent a target in the JAC Observing Tool) or TCS_CONFIG element
(JAC/JCMT configuration files).

A telescope can be specified explicitly in the constructor if desired.
This should only be relevant when parsing SpTelescopeObsComp XML.

  $cfg = new JAC::OCS::Config::TCS( XML => $xml,
                                    telescope => 'JCMT' );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;
  my %args = @_;

  # extract telescope
  my $tel = $args{telescope};
  delete $args{telescope};

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( %args,
                            $JAC::OCS::Config::CfgBase::INITKEY => { 
                                                                    Telescope => $tel,
                                                                    TAGS => {},
                                                                    SLEW => {},
                                                                    ROTATOR => {},
                                                                    ApertureCoords => [],
                                                                    DomeAzel => [],
                                                                   }
                          );
}

=item B<from_coord>

Construct a C<JAC::OCS::Config::TCS> object from the supplied argument
which may be one of C<Astro::Coords>, C<JAC::OCS::Config::TCS::BASE>
or C<JAC::OCS::Config::TCS> object. This simplifies methods that can
handle all types for coordinate extraction. If a TCS object is
supplied it is returned unchanged. BASE objects will be stored
directly under the internal tag (or "SCIENCE" if none defined) and
Astro::Coords objects will be associated with SCIENCE tag.

  $tcs = JAC::OCS::Config::TCS->from_coord( $object );

If a telescope name is present in the Astro::Coords object it will
be set in any newly created TCS object.

=cut

sub from_coord {
  my $class = shift;
  my $object = shift;
  return undef unless defined $object;

  throw JAC::OCS::Config::Error::BadArgs("from_coord called with unblessed argument")
    unless blessed($object);

  # if it is of this class just return it
  return $object if $object->isa( $class );

  # otherwise punt to JAC::OCS::Config::TCS::BASE
  # Use a default tag of "SCIENCE" (without translation since we will
  # be creating an empty TCS object)
  my $base = JAC::OCS::Config::TCS::BASE->from_coord( $object, "SCIENCE" );
  return undef unless defined $base; # should not happen

  # now that we have a BASE, create a new TCS object for it
  my $tcs = $class->new();

  # attach the base object
  $tcs->tags( $base->tag => $base );

  # set a telescope name if one is available
  my $c = $base->coords;
  my $tel = $c->telescope;
  $tcs->telescope( $tel->name ) if (defined $tel && defined $tel->name);

  # and we are done
  return $tcs;
}

=back

=head2 Accessor Methods

=over 4

=item B<isConfig>

Returns true if this object is derived from a TCS_CONFIG, false
otherwise (e.g if it is derived from a TOML configuration or not
derived from a DOM at all).

=cut

sub isConfig {
  my $self = shift;
  my $root = $self->_rootnode;

  my $name = $root->nodeName;
  return ( $name =~ /_CONFIG/ ? 1 : 0);
}

=item B<telescope>

The name of the telescope. This is present as an attribute to the TCS_CONFIG
element. If this class is reading TOML the telescope will not be defined.

=cut

sub telescope {
  my $self = shift;
  if (@_) {
    $self->{Telescope} = shift;
  }
  return $self->{Telescope};
}

=item B<aperture_name>

Name instrument aperture (if any) associated with this observation.

=cut

sub aperture_name {
  my $self = shift;
  if (@_) {
    $self->{ApertureName} = shift;
  }
  return $self->{ApertureName};
}

=item B<aperture_xy>

The aperture name can be associated with an override coordinate. This value
is optional. If it does not exist the telescope will assume that the aperture
name is sufficient.

  ($x, $y) = $tcs->aperture_xy;
  $tcs->aperture_xy( $x, $y );

=cut

sub aperture_xy {
  my $self = shift;
  if (@_) {
    JAC::OCS::Config::Error::BadArgs->throw( "Must supply 2 arguments to aperture_xy() not ".scalar(@_) )
        unless @_ == 2;
    @{$self->{ApertureCoords}} = @_;
  }
  return @{$self->{ApertureCoords}};
}

=item B<dome_mode>

Determines whether the dome is tracking the current telescope demand
position ("TELESCOPE") or the current telescope base position ("BASE").

Undef will cause the telescope to use default behaviour.

=cut

sub dome_mode {
  my $self = shift;
  if (@_) {
    my $mode = shift;
    if (defined $mode) {
      $mode = uc($mode);
      my $match;
      for my $test (qw/ CURRENT TELESCOPE STOPPED NEXT BASE/ ) {
        if ($mode eq $test) {
          $match = 1;
          last;
        }
      }
      if (!$match) {
        JAC::OCS::Config::Error::BadArgs->throw( "Supplied dome mode '$mode' does not match allowed values");
      }
    }
    $self->{DOME_MODE} = $mode;
  }
  return $self->{DOME_MODE};
}

=item B<dome_azel>

AZ and EL dome position aperture offsets. Only used if the dome mode
is set to STOPPED. The dome AZEL values are accepted even if mode is not
STOPPED. Mode is not updated.

  ($az, $el) = $tcs->dome_azel();
  $tcs->dome_azel( $az, $el );

=cut

sub dome_azel {
  my $self = shift;
  if (@_) {
    JAC::OCS::Config::Error::BadArgs->throw( "Must supply 2 arguments to dome_azel() not ".scalar(@_) )
        unless @_ == 2;
    @{$self->{DomeAzEl}} = @_;
  }
  return @{$self->{DomeAzEl}};
}

=item B<tags>

Hash containing the tags used in the TCS configuration as keys and the
corresponding coordinate information.

  my %tags = $cfg->tags;
  $cfg->tags( %tags );

The content of this hash is not part of the public interface. Use the
getCoords, getOffsets and getTrackingSystem methods for detailed
information. See also the C<getAllTargetInfo> method.

All tags can be removed by supplying a single undef

  $cfg->tags( undef );

See C<clearAllCoords> for the public implementation/

In scalar context returns the hash reference:

  $ref = $cfg->tags;

Currently, the values in the tags hash are C<JAC::OCS::Config::TCS::BASE>
objects.

=cut

sub tags {
  my $self = shift;
  if (@_) {
    # undef is a special case to clear all tags
    my @args = @_;
    @args = () unless defined $args[0];
    %{ $self->{TAGS} } = @_;
  }
  return (wantarray ? %{ $self->{TAGS} } : $self->{TAGS} );
}

=item B<slew>

Slewing options define how the telescope will slew to the science target
for the first slew of a configuration.

  $cfg->slew( %options );
  %options = $cfg->slew;

Allowed keys are OPTION, TRACK_TIME and CYCLE.

If OPTION is set, it will override any TRACK_TIME and CYCLE implied
definition.

If TRACK_TIME is set, OPTION will be set to 'TRACK_TIME' if OPTION is unset.

If CYCLE is set, OPTION will be set to 'TRACK_TIME' if OPTION is unset.

If OPTION is unset, but both TRACK_TIME and CYCLE are set, an error will be
triggered when the XML is created.

Default slew option is SHORTEST_SLEW.

Currently no validation is performed on the values of the supplied hash.

=cut

sub slew {
  my $self = shift;
  if (@_) {
    %{ $self->{SLEW} } = @_;
  }
  return %{ $self->{SLEW} };
}

=item B<rotator>

Image rotator options. This can be undefined.

  $cfg->rotator( %options );
  %options = $self->rotator;

Allowed keys are SLEW_OPTION, MOTION, SYSTEM and PA.
PA must refer to a reference to an array of C<Astro::Coords::Angle>
objects.

Currently no validation is performed on the values of the supplied hash.

=cut

sub rotator {
  my $self = shift;
  if (@_) {
    %{ $self->{ROTATOR} } = @_;
  }
  return %{ $self->{ROTATOR} };
}

=item B<isBlank>

Returns true if the object refers to a default position of 0h RA, 0 deg Dec
and blank target name, or alternatively contains zero tags.

=cut

sub isBlank {
  croak "Must implement this";
}

=item B<getTags>

Returns a list of all the coordinate tags available in the object.

  @tags = $cfg->getTags;

=cut

sub getTags {
  my $self = shift;
  my %tags = $self->tags;
  return keys %tags;
}

=item B<getNonSciTags>

Get the non-Science tags that are in use. This allows the science/Base tags
to be extracted using the helper methods, and then the remaining tags to
be processed without worrying about duplication of the primary tag.

=cut

sub getNonSciTags {
  my $self = shift;
  my %tags = $self->tags;
  my @tags = keys %tags;

  my @out = grep { $_ !~ /(BASE|SCIENCE)/i } @tags;
  return @out;
}

=item B<getSciTag>

Obtain the C<JAC::OCS::Config::TCS::BASE> object associated with the
science position.

  $sci = $tcs->getSciTag;

=cut

sub getSciTag {
  my $self = shift;
  my $tag = $self->_translate_tag_name( 'SCIENCE' );
  my %tags = $self->tags;
  return $tags{$tag};
}

=item B<getTarget>

Retrieve the Base or Science position as an C<Astro::Coords> object.

  $c = $cfg->getTarget;

Note that it is an error for there to be both a Base and a Science
position in the XML.

Also note that C<Astro::Coords> objects do not currently support
OFFSETS and so any offsets present in the XML will not be present in
the returned object. See the C<getTargetOffset> method.

=cut

sub getTarget {
  my $self = shift;
  return $self->getCoords("SCIENCE");
}


=item B<getCoords>

Retrieve the coordinate object associated with the supplied
tag name. Returns C<undef> if the specified tag is not present.

  $c = $cfg->getCoords( 'SCIENCE' );

The following synonyms are supported:

  BASE <=> SCIENCE
  REFERENCE <=> SKY

BASE/SCIENCE is equivalent to calling the C<getTarget> method.

Note that C<Astro::Coords> objects do not currently support OFFSETS
and so any offsets present in the XML will not be present in the
returned object. See the C<getOffset> method.

=cut

sub getCoords {
  my $self = shift;
  my $tag = shift;

  my %tags = $self->tags;

  # look for matching key or synonym
  $tag = $self->_translate_tag_name( $tag );

  return (defined $tag ? $tags{$tag}->coords : undef );
}

=item B<getTargetOffset>

Wrapper for C<getOffset> method. Returns any offset associated
with the base/science position.

=cut

sub getTargetOffset {
  my $self = shift;
  return $self->getOffset( "SCIENCE" );
}

=item B<getOffset>

Retrieve any offset associated with the specified target. Offsets are
returned as a C<Astro::Coords::Offset> objects.
Can return undef if no offset was specified.

  $ref = $cfg->getOffset( "SCIENCE" );

This method may well be obsoleted by an upgrade to C<Astro::Coords>.

=cut

sub getOffset {
  my $self = shift;
  my $tag = shift;

  my %tags = $self->tags;

  # look for matching key or synonym
  $tag = $self->_translate_tag_name( $tag );

  return (defined $tag ? $tags{$tag}->offset : undef );
}

=item B<getTrackingSystem>

Each Base position can have a different tracking system to the start
position specified in the target. (for example, a position can be
specified in RA/Dec but the telescope can be told to track in AZEL)

  $track_sys = $cfg->getTrackingSystem( "REFERENCE" );

=cut

sub getTrackingSystem {
  my $self = shift;
  my $tag = shift;

  my %tags = $self->tags;

  # look for matching key or synonym
  $tag = $self->_translate_tag_name( $tag );

  return (defined $tag ? $tags{$tag}->tracking_system : undef );
}

=item B<getAllTargetInfo>

Retrieves all the C<JAC::OCS::Config::TCS::BASE> objects associated
with this TCS configuration. In list context the base positions are
returned in a hash with keys matching the tag name.

  %all = $tcs->getAllTargetInfo;

In scalar context the positions are returned in a new lightweight
C<JAC::OCS::Config::TCS> object containing just the telescope
positions (and no secondary or observing area specification).

  $minitcs = $tcs->getAllTargetInfo;

=cut

sub getAllTargetInfo {
  my $self = shift;

  if (wantarray) {
    return $self->tags;
  } else {
    my $mtcs = $self->new();
    $mtcs->tags( $self->tags );
    return $mtcs;
  }
}

=item B<setAllTargetInfo>

Given either a TCS object or a hash with tag keys and
C<JAC::OCS::Config::TCS::BASE> values, override all the coordinate
information in this TCS object.

  $tcs->setAllTargetInfo( %basepos );
  $tcs->setAllTargetInfo( $tcs2 );

=cut

sub setAllTargetInfo {
  my $self = shift;
  if (scalar(@_) == 1) {
    my $tcs = shift;
    $self->tags( $tcs->tags );
  } else {
    $self->tags( @_ );
  }
  return;
}

=item B<getObsArea>

Return the C<JAC::OCS::Config::TCS::obsArea> associated with this
configuration.

 $obs = $tcs->getObsArea();

=cut

sub getObsArea {
  my $self = shift;
  return $self->{OBSAREA};
}


# internal routine that will not trigger regeneration of XML
sub _setObsArea {
  my $self = shift;
  $self->{OBSAREA} = check_class_fatal( "JAC::OCS::Config::TCS::obsArea", shift);
}

=item B<getSecondary>

Return the C<JAC::OCS::Config::TCS::Secondary> object associated with this
configuration.

 $obs = $tcs->getSecondary();

Can be undefined.

=cut

sub getSecondary {
  my $self = shift;
  return $self->{SECONDARY};
}


# internal routine that will not trigger regeneration of XML
sub _setSecondary {
  my $self = shift;
  $self->{SECONDARY} = check_class_fatal( "JAC::OCS::Config::TCS::Secondary",shift);
}

=item B<setTarget>

Specifies a new SCIENCE/BASE target.

  $tcs->setTarget( $c );

If a C<JAC::OCS::Config::TCS::BASE> object is supplied, this is stored
directly. If an C<Astro::Coords> object is supplied, it will be stored
in a C<JAC::OCS::Config::TCS::BASE> objects first (and offsets will be lost).

Note that offsets can only be included (currently) if an
C<JAC::OCS::Config::TCS::BASE> object is used.

=cut

sub setTarget {
  my $self = shift;
  $self->setCoords( "SCIENCE", shift );
}

=item B<setTargetSync>

Synchronize the targets in this object with those supplied. The bahaviour
varies depending on the contents of the argument:

 - if an Astro::Coords or JAC::OCS::Config::TCS::BASE object is given
   the SCIENCE position will be modified to this position (including
   offsets if a BASE and removing previous offsets if an Astro::Coords)
   and all tags that matched the original science 
   position will be modified to the new SCIENCE position, retaining
   offsets.

 - if a TCS object is given its contents will fully overwrite the
   target contents (see the setCoords method) unless the new object consists
   of solely a SCIENCE position. If it is just a SCIENCE position
   that position will be extracted and the above behaviour for
   BASE object above will occur.

 - If no SCIENCE position is currently set in this object then the supplied
   position will become the position and all others will be forced
   to use this position. If this results in multiple tags with identical
   positions and no offsets, an error will occur (since the intention was
   probably to replace the position in REFERENCE but retain offsets). This
   version will result in an empty list being returned since all positions
   are modified.

In list context returns all tags that were not modified. This will
occur if an absolute REFERENCE position has been used (for example).

  @unmodified = $tcs->setTargetSync( $object );

=cut

sub setTargetSync {
  my $self = shift;
  my $new = shift;

  throw JAC::OCS::Config::Error::FatalError("Please supply a coordinate")
    if !defined $new;
  throw JAC::OCS::Config::Error::FatalError("Argument to setTargetSync() must be blessed")
    if !blessed($new);

  # first see if we have to see if we are a TCS
  if ( $new->isa( ref($self) ) ) {
    my @tags = $new->getTags;
    if (@tags > 1) {
      # overwrite all because we have multiple tags
      $self->setCoords( $new );
      # nothing unmodified so have empty list
      return ();
    }

    # only have one so change $ncoord to be the only BASE position
    # Do not check to make sure it is SCIENCE
    $new = $new->getCoords( $tags[0] );
  }

  # Ensure that we have a base position with the correct SCIENCE tag
  my $deftag = $self->_translate_tag_name( "SCIENCE", 1);
  $new = JAC::OCS::Config::TCS::BASE->from_coord( $new, $deftag );
  throw JAC::OCS::Config::Error::FatalError("Error converting supplied argument to BASE object")
    unless defined $new;

  # Get all the available BASE positions
  my %tags = $self->getAllTargetInfo();

  # Get the SCIENCE position first (which is mandatory unless no tags exist)
  if (keys %tags) {
    my $scitag = $self->_translate_tag_name( "SCIENCE" );

    # we are allowed to run without a science - that simply removes
    # all the tests for nearness. We do test for OFFSETs though.

    my $science;
    $science =  $tags{$scitag} if defined $scitag;
  
    # get the new coordinates
    my $ncoord = $new->coords;

    # Get the actual science position for comparison
    my $scoord;
    $scoord = $science->coords if defined $science;

    # now loop over all tags
    for my $t (keys %tags) {
      my $base = $tags{$t};
      my $bcoord = $base->coords;

      # compare with science (if set)
      my $modify;
      if (defined $scoord) {
        # compare with the current position and modify
        # if they are within an arcsec
        my $distance = $bcoord->distance( $scoord );
        $modify = ( defined $distance && $distance->arcsec < 1 );
      } else {
        # modify since we do not have a science to compare with
        # but do need to check for OFFSETS
        $modify = 1;

        my $off = $base->offset;
        throw JAC::OCS::Config::Error::FatalError("Can not sync target positions if no SCIENCE/BASE is available and tag ".
                                                  $base->tag
                                                  ." does not contain offsets")
          if ( !defined $off || ($off->xoffset == 0 && $off->yoffset == 0));

      }
      if ($modify) {
        # can replace
        $base->coords( $ncoord );
        delete $tags{$t};
      }
    }
  }

  # force this BASE position to be the actual one
  $self->setTarget( $new );

  # %tags will now only contain tags that were not the same as SCIENCE.
  # ie those that were not modified
  return keys %tags;
}


=item B<setCoords>

Set the coordinate to be associated with the specified tag.

  $tcs->setCoords( "REFERENCE", $c );

If a C<JAC::OCS::Config::TCS::BASE> object is supplied, this is stored
directly. If an C<Astro::Coords> object is supplied, it will be stored
in a C<JAC::OCS::Config::TCS::BASE> objects.

If defined the supplied tag overrides any tag stored in the BASE object itself.
The TAG defaults to SCIENCE if none is defined.

  $tcs->setCoords( undef, $base );

Note that offsets can only be included (currently) if an
C<JAC::OCS::Config::TCS::BASE> object is used.

If a C<JAC::OCS::Config::TCS> object is given on its own (no tag), the
current tags in this object are replaced by all the tags from the supplied
object.

  $tcs->setCoords( $tcs );

=cut

sub setCoords {
  my $self = shift;
  my $tag = shift;
  my $c = shift;

  # First check to see if our tag is actually a complete TCS object
  if (UNIVERSAL::isa( $tag, __PACKAGE__) ) {
    $self->setAllTargetInfo( $tag );
    return;
  }

  # now can check to see if we have coordinates
  if (!defined $c) {
    throw JAC::OCS::Config::Error::FatalError('Usage: $cfg->setCoords(TAG,OBJ)');
  }

  # if we have a defined tag, we need to get its synonym
  if (defined $tag) {
    # look for matching key or synonym
    my $syn = $self->_translate_tag_name( $tag );

    # if we have a translated synonym that means we have an
    # existing tag that we are overwriting. Use that if so, else
    # this is a new tag.
    $tag = $syn if defined $syn;
  }

  # default tag is SCIENCE (or equivalent)
  my $deftag = $self->_translate_tag_name("SCIENCE",1);

  # Make sure we have a base (with default tag - unused if this is a BASE already)
  my $base = JAC::OCS::Config::TCS::BASE->from_coord( $c, $deftag );

  # get the tag from it if we did not have one explicitly
  $tag = $base->tag if !defined $tag;

  # force tag consistency
  $base->tag( $tag );

  # store it
  $self->tags->{$tag} = $base;

}

=item B<clearTarget>

Removes the SCIENCE/BASE target.

  $tcs->clearTarget();

=cut

sub clearTarget {
  my $self = shift;
  return $self->clearCoords( "SCIENCE" );
}

=item B<clearCoords>

Clear the target associated with the specified tag.

 $tcs->clearCoords( "REFERENCE" );

Synonyms are supported.

=cut

sub clearCoords {
  my $self = shift;
  my $tag = shift;

  # look for matching key or synonym
  $tag = $self->_translate_tag_name( $tag );

  delete($self->tags->{$tag}) if defined $tag;
}

=item B<clearAllCoords>

Remove all coordinates associated with this object. No tags will be associated
with this object.

 $tcs->clearAllCoords;

=cut

sub clearAllCoords {
  my $self = shift;
  $self->tags( undef );
}

=item B<tasks>

Name of the tasks that would be involved in reading this config.

 @tasks = $tcs->tasks();

Usually 'PTCS' plus SMU if a secondary configuration is available.

=cut

sub tasks {
  my $self = shift;
  my @tasks = ('PTCS');
  push( @tasks, $self->getSecondary->tasks ) if defined $self->getSecondary;
  return @tasks;
}

=item B<stringify>

Convert the class into XML form. This is either achieved simply by
stringifying the DOM tree (assuming object content has not been
changed) or by taking the object attributes and reconstructing the XML.

 $xml = $tcs->stringify;

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  # Should the <xml> and dtd prolog be included?
  # Should we create a stringified form directly or build a DOM
  # tree and stringify that?
  my $roottag = 'TCS_CONFIG';

  my $xml = '';

  # First the base element
  $xml .= "<$roottag ";

  # telescope
  my $tel = $self->telescope;
  $xml .= "TELESCOPE=\"$tel\"" if $tel;
  $xml .= ">\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  # Now add the constituents in turn
  $xml .= $self->_toString_base;
  $xml .= $self->_toString_slew;
  $xml .= $self->_toString_obsArea;
  $xml .= $self->_toString_secondary;
  $xml .= $self->_toString_rotator;
  $xml .= $self->_toString_aperture;
  $xml .= $self->_toString_dome;

  $xml .= "</$roottag>\n";

  # Indent the xml
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<dtdrequires>

Returns the names of any associated configurations required for this
configuration to be used in a full OCS_CONFIG. The TCS requires
'instrument_setup'.

  @requires = $cfg->dtdrequires();

=cut

sub dtdrequires {
  return ('instrument_setup');
}

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the TCS config.
Returns two node names (one for TOML and one for TCS_CONFIG).

 @names = $tcs->getRootElementName;

=cut

sub getRootElementName {
  return( "TCS_CONFIG", "SpTelescopeObsComp" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_translate_tag_name>

Given a tag name, check to see whether a tag of that name exists. If
it does, return it, if it doesn't look up the tag name in the synonyms
table. If the synonym exists, return that. Returns undef if the tag
does not currently exist in the object.

 $tag = $cfg->_translate_tag_name( $tag );

Alternatively, if the second (optional) argument is true, this method
does not rely on an existing tag but can translate on the basis of known tags.
In this case, "SCIENCE" would return "SCIENCE" even if no "SCIENCE" tag
currently exists. A tag is known if it exists as either a keyword or value
in the synonyms table. Returns undef if the tag is unknown. This option can
be used to insert new tagged coordinates.

 $tag = $cfg->_translate_tag_name( $tag, 1 );

=cut

{
  my %synonyms = ( BASE => 'SCIENCE',
                   SCIENCE => 'BASE',
                   REFERENCE => 'SKY',
                   SKY => 'REFERENCE',
                 );


  sub _translate_tag_name {
    my $self = shift;
    my $tag = shift;
    my $ignore_exists = shift;

    my %tags = $self->tags;

    if (exists $tags{$tag} ) {
      return $tag;
    } elsif (exists $synonyms{$tag} && exists $tags{ $synonyms{$tag} } ) {
      # Synonym exists
      return $synonyms{$tag};
    } else {
      if ($ignore_exists) {
        # see if this tag would be valid in general even if it does not currently
        # exist
        for my $v ( values %synonyms ) {
          return $v if $tag eq $v;
        }
        for my $k (keys %synonyms) {
          return $synonyms{$k} if $tag eq $k;
        }
      }

      return undef;
    }
  }
}

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the TCS XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Get the telescope name (if possible)
  $self->_find_telescope();

  # instrument aperture name
  $self->_find_instrument_aperture_name();

  # Look for BASE positions
  $self->_find_base_posns();

  # SLEW settings
  $self->_find_slew();

  # Observing Area
  $self->_find_obsArea();

  # Secondary mirror configuration
  $self->_find_secondary();

  # Beam rotator configuration
  $self->_find_rotator();

  # Dome control
  $self->_find_dome();

  return;
}

=item B<_find_telescope>

Extract telescope name from the DOM tree. Non-fatal if a telescope
can not be located.

The object is updated if a telescope is located.

=cut

sub _find_telescope {
  my $self = shift;
  my $el = $self->_rootnode;

  my $tel = $el->getAttribute( "TELESCOPE" );

  $self->telescope( $tel ) if $tel;
}

=item B<_find_instrument_aperture_name>

Find the instrument aperture name.

=cut

sub _find_instrument_aperture_name {
  my $self = shift;
  my $el = $self->_rootnode;
  my $inst_ap = find_children( $el, "INST_AP", min => 0, max => 1 );
  return unless defined $inst_ap;
  my %params = find_attr( $inst_ap, "X", "Y", "NAME" );

  my $havexy = 0;
  if (exists $params{X} && exists $params{Y}) {
    $self->aperture_xy( $params{X} , $params{Y} );
    $havexy = 1;
  }

  if (defined $params{NAME}) {
    $self->aperture_name( $params{NAME} );
  } elsif ($havexy) {
    # better put something in to go with the coordinates
    $self->aperture_name( "UNNAMED_AP" );
  }
  return;
}

=item B<_find_slew>

Find the slewing options.

The object is updated if a SLEW is located.

=cut

sub _find_slew {
  my $self = shift;
  my $el = $self->_rootnode;

  # SLEW is now optional (it used to be mandatory for TCS_CONFIG)
  my $slew = find_children( $el, "SLEW", min => 0, max => 1);
  if ($slew) {
    my %sopt = find_attr( $slew, "OPTION", "TRACK_TIME","CYCLE");
    $self->slew( %sopt );
  }

}

=item B<_find_dome>

Find the DOME options.

The object state is updated.

=cut

sub _find_dome {
  my $self = shift;
  my $el = $self->_rootnode;

  # DOME is optional
  my $dome = find_children( $el, "DOME", min => 0, max => 1);
  if ($dome) {
    my %dopt= find_attr( $dome, "MODE", "AZ", "EL" );
    $self->dome_mode( $dopt{MODE} );
    if ($dopt{MODE} eq 'STOPPED') {
      if (defined $dopt{AZ} && defined $dopt{EL}) {
        $self->dome_azel( $dopt{AZ}, $dopt{EL} );
      }
    }
  }
}

=item B<_find_base_posns>

Extract target information from the BASE elements in the TCS.
An exception will be thrown if no base positions can be found.

  $cfg->_find_base_posns();

The state of the object is updated.

=cut

sub _find_base_posns {
  my $self = shift;
  my $el = $self->_rootnode;

  # We need to parse each of the BASE positions specified
  # Usually SCIENCE, REFERENCE or BASE and SKY

  # We should find all the BASE entries and parse them in turn.
  # Note that we have to look out for both BASE (the modern form)
  # and "base" the old-style. It is possible for there to be no BASE
  # elements.

  my @base = $el->findnodes( './/BASE | .//base ');

  # get the telescope name
  my $tel = $self->telescope;

  # For each of these nodes we need to extract the target information
  # and the tag
  my %tags;
  for my $b (@base) {

    # Create the object from the dom.
    my $base = new JAC::OCS::Config::TCS::BASE( DOM => $b,
                                                telescope => $tel);
    my $tag = $base->tag;
    $tags{$tag} = $base;

  }

  # Store the coordinate information
  $self->tags( %tags );

}

=item B<_find_obsArea>

Extract observing area information from the XML.

=cut

sub _find_obsArea {
  my $self = shift;
  my $el = $self->_rootnode;

  # since there can only be at most one optional obsArea, pass this rootnode
  # to the obsArea constructor but catch the special case of XMLConfigMissing
  try {
    my $b = 1;
    my $obsa = new JAC::OCS::Config::TCS::obsArea( DOM => $el );
    $self->_setObsArea( $obsa ) if defined $obsa;
  } catch JAC::OCS::Config::Error::XMLConfigMissing with {
    # this error is okay
  };

}

=item B<_find_rotator>

Find the image rotator settings. This field is optional.
The object is updated if a ROTATOR is located.

=cut

sub _find_rotator {
  my $self = shift;
  my $el = $self->_rootnode;

  my $rot = find_children( $el, "ROTATOR", min => 0, max => 1);
  if ($rot) {
    my %ropt = find_attr( $rot, "SYSTEM","SLEW_OPTION", "MOTION");

    # Allow multiple PA children
    my @pa = find_pa( $rot );

    $self->rotator( %ropt,
                    ( @pa ? (PA => \@pa) : () ),
                  );
  }

}

=item B<_find_secondary>

Specifications for the secondary mirror motion during the observation.
The object is update if a SECONDARY element is located.

=cut

sub _find_secondary {
  my $self = shift;
  my $el = $self->_rootnode;

  # since there can only be at most one optional SECONDARY, pass this rootnode
  # to the SECONDARY constructor but catch the special case of XMLConfigMissing
  try {
    my $sec = new JAC::OCS::Config::TCS::Secondary( DOM => $el );
    $self->_setSecondary( $sec ) if defined $sec;
  } catch JAC::OCS::Config::Error::XMLConfigMissing with {
    # this error is okay
  };

}

=back

=head2 Stringification

=over 4

=item _toString_base

Create the target XML (and associated tags).

 $xml = $tcs->_toString_base();

=cut

sub _toString_base {
  my $self = shift;

  # First get the allowed tags
  my %t = $self->tags;

  my $xml = "";
  for my $tag (keys %t) {
    $xml .= $t{$tag}->stringify(NOINDENT => 1);
  }

  return $xml;
}

=item _toString_slew

Create string representation of the SLEW information.

 $xml = $tcs->_toString_slew();

=cut

sub _toString_slew {
  my $self = shift;
  my $xml = '';
  if ($self->isDOMValid("SLEW")) {
    my $el = $self->_rootnode;
    my $slew = find_children( $el, "SLEW", min => 0, max => 1);
    $xml .= $slew->toString if $slew;
  } else {
    # Reconstruct XML
    my %slew = $self->slew;

    # Slew is mandatory and we can default it to match the DTD if we do not
    # have an explicit value
    $xml .= "\n<!-- Set up the SLEW method here -->\n\n";

    # Normalise the hash
    if (!$slew{OPTION}) {
      # no explicit option
      if (defined $slew{CYCLE} && defined $slew{TRACK_TIME}) {
        throw JAC::OCS::Error::FatalError("No explicit Slew option but CYCLE and TRACK_TIME are specified. Please fix ambiguity.");
      } elsif (defined $slew{CYCLE}) {
        $slew{OPTION} = 'CYCLE';
      } elsif (defined $slew{TRACK_TIME}) {
        $slew{OPTION} = 'TRACK_TIME';
      } else {
        # default to longest track
        $slew{OPTION} = 'SHORTEST_SLEW';
      }
    }	
    if ($slew{OPTION} eq 'CYCLE' && !defined $slew{CYCLE}) {
      throw JAC::OCS::Error::FatalError("Slew option says CYCLE but cycle is not specified");
    } elsif ($slew{OPTION} eq 'TRACK_TIME' && !defined $slew{TRACK_TIME}) {
      throw JAC::OCS::Error::FatalError("Slew option says TRACK_TIME but track time is not specified");
    }

    $xml .= "<SLEW OPTION=\"$slew{OPTION}\" ";
    $xml .= "TRACK_TIME=\"$slew{TRACK_TIME}\" "
      if $slew{OPTION} eq 'TRACK_TIME';
    $xml .= "CYCLE=\"$slew{CYCLE}\" "
      if $slew{OPTION} eq 'CYCLE';
    $xml .= " />\n";
  }
  return $xml;
}

=item _toString_obsArea

Create string representation of observing area.

=cut

sub _toString_obsArea {
  my $self = shift;
  my $obs = $self->getObsArea;
  return "\n<!-- Set up observing area here -->\n\n".
    (defined $obs ? $obs->stringify(NOINDENT => 1) : "" );
}

=item _toString_secondary

Create the XML corresponding to the SECONDARY element.

=cut

sub _toString_secondary {
  my $self = shift;
  my $sec = $self->getSecondary;
  return "\n<!-- Set up Secondary mirror behaviour here -->\n\n".
    (defined $sec ? $sec->stringify(NOINDENT => 1) : "" );
}

=item B<_toString_aperture>

Create string representation of aperture information.

 $xml = $tcs->_toString_aperture();

=cut

sub _toString_aperture {
  my $self = shift;
  my $xml = '';
  if (defined $self->aperture_name) {
    $xml .= "<INST_AP NAME=\"".$self->aperture_name."\" ";
    my @xy = $self->aperture_xy();
    if (@xy) {
      $xml .= "X=\"$xy[0]\" Y=\"$xy[1]\" ";
    }
    $xml .= "/>\n";
  }
  return $xml;
}

=item B<_toString_dome>

Create string representation of the DOME information (if present).

 $xml = $tcs->_toString_dome();

=cut

sub _toString_dome {
  my $self = shift;
  my $xml = '';
  my $dmode = $self->dome_mode;
  if (defined $dmode) {
    $xml = "<DOME MODE=\"$dmode\" ";
    if ($dmode eq 'STOPPED') {
      my @azel = $self->dome_azel;
      if (@azel) {
        $xml .= "AZ=\"$azel[0]\" EL=\"$azel[1]\" ";
      }
    }
    $xml .= "/>\n";
  }
  return $xml;
}

=item _toString_rotator

Create string representation of the ROTATOR element.

 $xml = $tcs->_toString_rotator();

=cut

sub _toString_rotator {
  my $self = shift;
  my $xml = '';
  if ($self->isDOMValid("ROTATOR")) {
    my $el = $self->_rootnode;
    my $rot = find_children( $el, "ROTATOR", min => 0, max => 1);
    $xml .= $rot->toString if $rot;
  } else {
    # Reconstruct XML
    my %rot = $self->rotator;
    # Check we have something. ROTATOR is an optional element
    $xml .= "\n<!-- Configure the instrument rotator here -->\n\n";
    if (keys %rot) {

      # Check that the slew option is okay
      my %slew = $self->slew;
      if ($rot{SLEW_OPTION} eq 'TRACK_TIME' &&
          !exists $slew{TRACK_TIME}) {
        throw JAC::OCS::Config::Error::FatalError("Rotator is attempting to use TRACK_TIME slew option but no track time has been defined in the SLEW parameter");
      }

      $xml .= "<ROTATOR SYSTEM=\"$rot{SYSTEM}\"\n";
      $xml .= "         SLEW_OPTION=\"$rot{SLEW_OPTION}\"\n"
        if exists $rot{SLEW_OPTION};
      $xml .= "         MOTION=\"$rot{MOTION}\"\n" 
        if exists $rot{MOTION};
      $xml .= ">\n";

      # PA is optional
      if (exists $rot{PA} && @{$rot{PA}}) {
        for my $pa (@{$rot{PA}}) {
          $xml .= "  ". pa_to_xml( $pa );
        }
      }

      $xml .= "</ROTATOR>\n";

    }
  }
  return $xml;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The TCS XML configuration specification is documented in OCS/ICD/006
with a DTD available at
http://docs.jach.hawaii.edu/JCMT/OCS/ICD/006/tcs.dtd. A
schema is also available as part of the TOML definition used by the
JAC Observing Tool, but note that the XML dialects differ in their uses
even though they use the same low-level representation of an astronomical
target.

=head1 HISTORY

This code was originally part of the C<OMP::MSB> class and was then
extracted into a separate C<TOML::TCS> module. During work on the new
ACSIS translator it was felt that a Config namespace was more correct
and so the C<TOML> namespace was deprecated.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright 2002-2005 Particle Physics and Astronomy Research Council.
All Rights Reserved.

This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful,but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program; if not, write to the Free Software Foundation, Inc., 59 Temple
Place,Suite 330, Boston, MA  02111-1307, USA

=cut

1;
