package JAC::OCS::Config::TCS::BASE;

=head1 NAME

JAC::OCS::Config::TCS::BASE - Parse and modify TCS/TOML Base position XML

=head1 SYNOPSIS

  use JAC::OCS::Config::TCS::BASE;

  $cfg = new JAC::OCS::Config::TCS::BASE( File => 'base.ent');
  $cfg = new JAC::OCS::Config::TCS::BASE( XML => $xml );
  $cfg = new JAC::OCS::Config::TCS::BASE( DOM => $dom );

  $base  = $cfg->coords;
  $tag   = $cfg->tag;

=head1 DESCRIPTION

This class can be used to parse and modify the telescope base position
XML. If multiple base positions are present in the XML it will only process
the first.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;
use Scalar::Util qw/ blessed /;
use Astro::Telescope;
use Astro::Coords;
use Astro::Coords::Offset;
use Astro::Coords::Angle;
use Data::Dumper;

use JAC::OCS::Config::XMLHelper qw/ get_pcdata get_pcdata_multi find_attr
				    indent_xml_string
				    /;
use JAC::OCS::Config::TCS::Generic qw/ coords_to_xml offset_to_xml find_offsets /;
use JAC::OCS::Config::Error;

use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = "1.01";

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new BASE configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::BASE( File => $file );
  $cfg = new JAC::OCS::Config::BASE( XML => $xml );
  $cfg = new JAC::OCS::Config::BASE( DOM => $dom );

If there is a chance that the telescope coordinates extracted by this
routine require a telescope in their construction (especially HA/Dec)
then a "telescope" name or C<Astro::Telescope> object must be provided
(and that name must be understandable by C<Astro::Telescope>).

  $cfg = new JAC::OCS::Config::BASE( DOM => $dom, telescope => 'JCMT' );
  $cfg = new JAC::OCS::Config::BASE( DOM => $dom, telescope => $tel );

The constructor will locate the BASE configuration in either a
a 'BASE' or 'base' element.

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;
  my %args = @_;

  my $tel = $args{telescope};
  delete $args{telescope};

  # Now call base class with all the supplied options
  # and initialise the telescope
  return $self->SUPER::new( %args,
			    $JAC::OCS::Config::CfgBase::INITKEY => {
								    TELESCOPE => $tel,
								   }
			  );
}

=item B<from_coord>

Construct a C<JAC::OCS::Config::TCS::BASE> object from either an
C<Astro::Coords> object or if the argument is already a
C<JAC::OCS::Config::TCS::BASE> object return it.

 $base = JAC::OCS::Config::TCS::BASE->from_coord( $object, $tag );

This allows code that is using coordinates to always assume a BASE
object. The second argument is the tag name to use only in the event that
an C<Astro::Coords> object is supplied. It is ignored if a BASE is given.
"SCIENCE" is used if a tag is required and was not supplied.

If a new BASE is created the tracking system is set to the magic value of
"TRACKING". This is done because the TCS used to have a bug and defaulted
to the previous tracking system (may not be necessary now but being explicit
does no harm).

Returns C<undef> if given undef, and throws an exception if the argument
is not recognized.

=cut

sub from_coord {
  my $class = shift;
  my $object = shift;
  return undef unless defined $object;
  my $tag = shift;

  # see if we are blessed
  throw JAC::OCS::Config::Error::BadArgs("from_coord called with unblessed argument")
    unless blessed($object);

  # if it is of this class just return it
  return $object if $object->isa( $class );

  # is it a Astro::Coords?
  $tag = (defined $tag ? "SCIENCE" : $tag);
  my $base;
  if ($object->isa("Astro::Coords")) {
    # create a new BASE object
    $base = $class->new();
    $base->coords( $object );
    # set the tag
    $base->tag( $tag );
    # And tracking system
    $base->tracking_system( "TRACKING" );
  } elsif ($object->can( "coords") && $object->can( "tag" )) {
    # special case an object that acts like a BASE. This code was
    # used in TCS.pm but can not remember the significance.
    $base = $object;
  } else {
    throw JAC::OCS::Config::Error::BadArgs("Supplied coordinate to from_coord() is neither and Astro::Coords nor JAC::OCS::Config::TCS::BASE");
  }

  return $base;
}

=back

=head2 Accessor Methods

=over 4

=item B<tag>

The string identifier associated with this base position. Usually
one of SCIENCE/BASE, REFERENCE/SKY or GUIDE. Can be used to get or
set the tag name.

 $tag = $cfg->tag;
 $cfg->tag( "SCIENCE" );

=cut

sub tag {
  my $self = shift;
  if (@_) {
    $self->{TAG} = uc(shift);
  }
  return $self->{TAG};
}

=item B<coords>

Return (or set) the C<Astro::Coords> coordinate object representing
this base position.

  $c = $cfg->coords();

=cut

sub coords {
  my $self = shift;
  if (@_) {
    my $arg = shift;
    throw JAC::OCS::Config::Error::FatalError("Coordinate object is not of correct class")
      unless $arg->isa( "Astro::Coords" );
    $self->{Coords} = $arg;
  }
  return $self->{Coords};
}

=item B<offset>

Some base positions require tangent/sin offsets from the reference coordinate.
This methods returns those as an C<Astro::Coords::Offset> object. In the
future this functionality may be embedded in the C<Astro::Coords> object
itself.

An undef argument can be used to clear the offset.

=cut

sub offset {
  my $self = shift;
  if (@_) {
    # undef if allowed
    my $arg = shift;
    throw JAC::OCS::Config::Error::FatalError("Offset object is not of correct class")
      if (defined $arg && !$arg->isa( "Astro::Coords::Offset" ));
    $self->{Offset} = $arg;
  }
  return $self->{Offset};
}

=item B<tracking_system>

Each Base position can have a different tracking system to the start
position specified in the target. (for example, a position can be
specified in RA/Dec but the telescope can be told to track in AZEL)

  $track_sys = $cfg->tracking_system();

=cut

sub tracking_system {
  my $self = shift;
  if (@_) {
    $self->{TRACKING_SYSTEM} = shift;
  }
  return $self->{TRACKING_SYSTEM};
}

=item B<stringify>

XML representation of BASE position.

 $xml = $b->stringify;

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';

  # Version declaration
  $xml .= $self->_introductory_xml();

  $xml .= "<!-- BASE element contains target, offset and tracking system -->\n";

  my $tag = $self->tag;
  $tag = 'Base' if $tag eq 'BASE'; # special case

  my $roottag = 'BASE';
  $xml .= "<$roottag TYPE=\"$tag\">\n";
  $xml .= "  <!-- First define a target -->\n";

  my $c = $self->coords;
  # Convert Astro::Coords object to XML
  $xml .= coords_to_xml( $c );

  # Now offsets
  my $o = $self->offset;
  if ($o) {
    $xml .= "  <!-- Now define an offset from the target position -->\n";
    $xml .= offset_to_xml( $o );
  }

  # and tracking system
  my $ts = $self->tracking_system;
  if (defined $ts) {
    $xml .= "  <!-- Select a tracking coordinate system -->\n";
    if ($ts eq 'TRACKING') {
      # We can not have a tracking system of TRACKING so we have to choose
      # one based on the system used to initially populate the Astro::Coords
      # object
      my %syslut = ( # Map "native" to TCS
                    apparent => "APP",
                    radec => "ICRS",      # Use this rather than J2000
                    radec1950 => "B1950",
                    glonglat => "GAL",
                    hadec => "HADEC",
                    azel => "AZEL",
                   );

      my $native = $c->native;
      if (exists $syslut{$native}) {
        $ts = $syslut{$native};
      } else {
        $xml .= "<!-- Tracking system was TRACKING and native coord system was ".
          (defined $native ? $native : "undefind") . " but the translator does not understand this so choosing J2000 -->\n";
        $ts = 'J2000';
      }
    }
    $xml .= "  <TRACKING_SYSTEM SYSTEM=\"$ts\" />\n";
  }

  $xml .= "</$roottag>\n";

  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=begin __PRIVATE_ATTRIBUTES__

=item B<_telescope>

Name of telescope to attach to coordinates generated from parsing.
Not used when generating XML. Can also be an object.

=cut

sub _telescope {
  my $self = shift;
  if (@_) {
    $self->{TELESCOPE} = shift;
  }
  return $self->{TELESCOPE};
}

=end __PRIVATE_ATTRIBUTES__

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the element that should be the root
node of the XML tree corresponding to the TCS BASE position config.
Returns two node names (one for modern system, and one for backwards
compatibility).

 @names = $tcs->getRootElementName;

=cut

sub getRootElementName {
  return( "BASE", "base" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the TCS XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Look for BASE positions
  $self->_find_base_posn();

  return;
}

=item B<_find_base_posn>

Extract target information from the BASE elements in the TCS.
An exception will be thrown if no base positions can be found.

  $cfg->_find_base_posn();

The state of the object is updated.

=cut

sub _find_base_posn {
  my $self = shift;
  my $el = $self->_rootnode;

  # Need to support two versions of the TCS XML.
  # Old version has
  # <base>
  #  <target type="SCIENCE">
  #       ...
  # New version has:
  # <BASE TYPE="Base">
  #   <target>
  #        ....
  # and changes hmsdeg and degdeg to spherSystem

  # Get the name of the root node
  my $name = $el->nodeName;

  # get the telescope name
  my $tel = $self->_telescope;

  # Depending on the name, we need to adjust how we process the tree
  my $tag;
  if ($name eq 'BASE') {
    $tag = $el->getAttribute( 'TYPE' );
  } elsif ($name eq 'base') {
    my ($tagnode) = $el->findnodes( './/target' );
    $tag = $tagnode->getAttribute('type');
  } else {
    throw JAC::OCS::Config::Error::XMLBadStructure("Can find neither 'BASE' nor 'base' element!");
  }
  throw JAC::OCS::Config::Error::XMLBadStructure("Unable to find tag associated with this base position")
    unless defined $tag;

  # Now need to find the target
  my ($target) = $el->findnodes( './/target' );

  throw JAC::OCS::Config::Error::XMLBadStructure("Unable to find target inside BASE element\n") 
    unless $target;

  # Use case insensitive BASE vs Base
  $tag = "BASE" if $tag eq 'Base';

  # Store the tag
  $self->tag( $tag );

  # Now extract the coordinate information
  $self->coords( $self->_extract_coord_info( $target, $tel ) );

  # Look for tracking system
  my ($tracksys) = $el->findnodes( './/TRACKING_SYSTEM' );
  if ($tracksys) {
    $self->tracking_system($tracksys->getAttribute( "SYSTEM" ));
  }

  # Look for an offset
  my @offsets = find_offsets( $el,
			      min => 0,
			      max => 1,
			      tracking => $self->tracking_system);

  # Store in object
  $self->offset( $offsets[0] ) if @offsets;

  return;
}

=item B<_extract_coord_info>

This routine will parse a TCS XML "target" element (supplied as a
node) and return the relevant information in the form of a
C<Astro::Coords> object.  Does not know about the TYPE associated with
the coordinate.

 $coords = $self->_extract_coord_info( $element );
 $coords = $self->_extract_coord_info( $element, $tel );

An optional telescope name or C<Astro::Telescope> object can be
provided, although some coordinate systems (e.g. HA/Dec) require the
telescope to be provided during object construction. The telescope
name must be understood by C<Astro::Telescope>.

=cut

sub _extract_coord_info {
  my $self = shift;
  my $target = shift;
  my $tel = shift;

  # Somewhere to store the information
  my $c;

  # Create tel object if necessary
  if (defined $tel && !blessed $tel) {
    $tel = new Astro::Telescope( $tel );
  }

  # Get the target name
  my $name = get_pcdata($target, "targetName");
  $name = '' unless defined $name;

  # Now we need to look for the coordinates. If we have hmsdegSystem
  # or degdegSystem (for Galactic) we translate those to a nice easy
  # J2000. If we have conicSystem or namedSystem then we have a moving
  # source on our hands and we have to work out it's azel dynamically
  # If we have a degdegSystem with altaz we can always schedule it.
  # spherSystem now replaces hmsdegsystem and degdegsystem

  # Search for the element matching (this will be targetName 90% of the time)
  # We know there is only one system element per target

  # Find any nodes that end with "System"
  my ($system) = $target->findnodes('.//*[contains(name(),"System")]');

  # Get the coordinate system name
  my $sysname = $system->getName;

  # Get the coordinate frame. This is either "type", "TYPE" or "SYSTEM"
  # depending on the age of the XML. SYSTEM is the current version.
  # Note that is SYSTEM is not provided, the DTD will provide a default
  # if a DTD is specified.
  my $type;
  if ($sysname eq 'spherSystem') {
    $type = $system->getAttribute("SYSTEM");
  } else {
    my $lc = $system->getAttribute("type");
    my $uc = $system->getAttribute("TYPE");

    # for old files if we have TYPE and "type"
    # we should use "TYPE" to stop the DTD defaulting for "type"
    $type = ( defined $uc ? $uc : $lc );
  }

  throw JAC::OCS::Config::Error::FatalError("Unable to determine the coordinate system. Have you included a reference to the TCS DTD?")
    if !defined $type;


  # hmsdeg and degdeg are old variants of spherSystem
  if ($sysname eq "hmsdegSystem" or $sysname eq "degdegSystem"
     or $sysname eq 'spherSystem') {

    # Get the "long" and "lat"
    my %cc = get_pcdata_multi($system, "c1", "c2" );

    # degdeg uses different keys to hmsdeg
    #print "System: $sysname\n";
    my ($long ,$lat);
    my %coords;
    # Note that the PTCS can handle B1900 J2006.4 BUT the ICD does not allow them
    # so they should not technically be in the XML. Given that we can support them
    # we proceed as if they are allowed.
    if ($type =~ /^[BJ]\d\d\d\d/) {

      # Proper motions and parallax
      my %pm = get_pcdata_multi( $system, "epoch", "pm1", "pm2", "parallax");

      %coords = ( ra => $cc{c1}, dec => $cc{c2}, type => $type);

      $coords{parallax} = $pm{parallax} if defined $pm{parallax};
      $coords{epoch} = $pm{epoch} if defined $pm{epoch};
      if (defined $pm{pm1} || defined $pm{pm2}) {
	$pm{pm1} ||= 0.0;
	$pm{pm2} ||= 0.0;
	$coords{pm} = [ $pm{pm1}, $pm{pm2} ];
      }


    } elsif ($type =~ /gal/i) {
      %coords = ( long => $cc{c1}, lat => $cc{c2}, 
		  type => 'galactic', units=>'deg' );
    } elsif ($type eq 'Az/El' || $type eq 'AZEL') {
      my $unit = ($cc{c1} =~ /:/ or $cc{c2} =~ /:/)
               ? 'sexagesimal'
               : 'degrees';
      %coords = ( az => $cc{c1}, el => $cc{c2}, units => $unit );
    } elsif ($type eq 'HADEC') {
      throw JAC::OCS::Config::Error::FatalError("HA/Dec requires a telescope but no telescope is defined!") unless defined $tel;

      %coords = ( ha => $cc{c1}, dec => $cc{c2}, units => 'sex',
		  tel => $tel );

    } else {
      throw JAC::OCS::Config::Error::FatalError("Do not know how to parse '$sysname' coordinates of type '$type'");
    }

    # Get the velocity information
    my ($vel, $sor, $defn);
    my ($rv) = $system->findnodes(".//rv");
    if ($rv) {
      my %vel = find_attr( $rv, "defn", "frame");
      $vel{rv} = get_pcdata( $system, "rv" );
      if ($vel{defn} eq 'REDSHIFT') {
	$coords{redshift} = $vel{rv};
      } else {
	$coords{rv} = $vel{rv};
	$coords{vdefn} = $vel{defn};
	$coords{vframe} = $vel{frame};
      }
    }

    # Differential tracking rates
    my ($drate) = $system->findnodes( ".//diffRates");
    if ($drate) {
      warn "Differential tracking rates are not (yet) supported\n";
    }


    # Create a new coordinate object
    $c = new Astro::Coords( %coords,
			    name => $name);

    throw JAC::OCS::Config::Error::FatalError("Error reading coordinates from XML for target $name / system $sysname. Tried ".
                                 Dumper(\%coords))
      unless defined $c;

  } elsif ($sysname eq "conicSystem") {

    # Orbital elements. We need to get the (up to) 8 numbers
    # and store them in an Astro::Coords.

    # Lookup table for XML to PAL
    # should probably put this in Astro::Coords::Elements
    # and default to knowledge of units if, for example,
    # supplied as 'inclination' rather than 'orbinc'
    # XML should have epoch in MJD without modification
    my %lut = (EPOCH  => 'epoch',
               ORBINC => 'inclination',
               ANODE  => 'anode',
               PERIH  => 'perihelion',
               AORQ   => 'aorq',
               E      => 'e',
               AORL   => 'LorM',
               DM     => 'n',
               EPOCHPERIH => 'epochPerih',
              );

    # Create an elements hash
    my %elements;
    for my $el (keys %lut) {

      # Skip if we are dealing with "comet" or minor planet
      # and are at DM
      next if ($el eq 'DM' && ($type =~ /Comet/i || $type =~ /Minor/i));

      # AORL is not relevant for comet
      next if ($el eq 'AORL' && $type =~ /Comet/i);
      # Get the value from XML
      my $value = get_pcdata( $system, $lut{$el});

      # Convert to radians
      if ($el =~ /^(ORBINC|ANODE|PERIH|AORL|DM)$/) {
        # Convert to radians
        my $ang = Astro::Coords::Angle->new( $value, units => "deg" );
        $value = $ang->radians;
      }

      # Store the value
      $elements{$el} = $value;

    }
    $c = Astro::Coords->new( elements => \%elements,
			     name => $name);

    throw JAC::OCS::Config::Error::FatalError("Error reading coordinates from XML for target $name. Tried elements".
                                 Dumper(\%elements))
      unless defined $c;

  } elsif ($sysname eq "namedSystem") {

    throw JAC::OCS::Config::Error::FatalError("No planet name supplied for namedSystem")
      unless $name;

    # A planet that the TCS already knows about
    $c = Astro::Coords->new( planet => $name);

    throw JAC::OCS::Config::Error::FatalError("Unable to process planet '$name'\n")
      unless defined $c;

  } else {
    throw JAC::OCS::Config::Error::FatalError("Target system ($sysname) not recognized\n");
  }

  # Store the telescope if we have it
  $c->telescope( $tel ) if defined $tel;

  return $c;
}

=back

=end __PRIVATE_METHODS__

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
