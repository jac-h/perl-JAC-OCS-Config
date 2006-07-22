package JAC::OCS::Config::Instrument;

=head1 NAME

JAC::OCS::Config::Instrument - Parse and modify OCS Instrument configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::Instrument;

  $cfg = new JAC::OCS::Config::Instrument( File => 'instrument_rxa.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the Instrument
configuration information present in the INSTRUMENT element of an OCS
configuration.  Note that this XML is not strictly configuration since
it is present in the configuration XML to allow validation but is
itself sent to the frontend for initialisation.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;
use Astro::Coords::Angle;
use Astro::Coords::Offset;

use JAC::OCS::Config::Error qw| :try |;
use JAC::OCS::Config::Units;

use JAC::OCS::Config::XMLHelper qw(
				   find_children
				   find_attr
				   indent_xml_string
				   get_pcdata
				  );


use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/);

# Supported keys for POINTING_OFFSET element
my @POINTING_MODEL = qw/ CA IE /;


=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new Instrument configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::Instrument( File => $file );
  $cfg = new JAC::OCS::Config::Instrument( XML => $xml );
  $cfg = new JAC::OCS::Config::Instrument( DOM => $dom );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								    RECEPTORS=>{},
								    XYPOS => [],
								    POINTING_OFF => {},
								    SMU_OFF => [],
								   }
			  );
}

=back

=head2 Accessor Methods

Note that there is no C<tasks> method associated with this class
because this XML represents initialisation rather than
configuration. See the C<JAC::OCS::Config::Frontend> class for the
task mapping for configuration.

=over 4

=item B<receptors>

Information concerning each receptor in the instrument.

 %receptors = $ins->receptors;
 $ins->receptors( %receptors );

The hash is indexed by the receptor ID (and so is usable to generate
a mask for the frontend) and each value is a reference to a hash containing
the following information

 health -  ON, OFF, or UNSTABLE
 xypos  -  X coordinate (arcsec) of the pixel relative to the focal plane &
           Y coordinate (arcsec) of the pixel relative to the focal plane
 pol_type - Polarisation type for this pixel (eg Linear)
 refpix -  ID of reference pixel for gain calibration
 sensitivity - Relative sensitivity of this pixel to the reference pixel
 angle  - polarization angle (Astro::Coords::Angle object)
 band   - waveband associated with this receptor (A,B,C, or D)

The reference pixel should refer to one of the pixels in this receptor
hash.

=cut

sub receptors {
  my $self = shift;
  if (@_) {
    %{$self->{RECEPTORS}} = @_;
  }
  return %{$self->{RECEPTORS}};
}

=item B<receptor>

Retrieve information about a specific receptor. Hash keys match those
described in the C<receptors> method.

  %info = $inst->receptor( "H00" );

=cut

sub receptor {
  my $self = shift;
  my $recid = shift;
  my %rec = $self->receptors;
  return (exists $rec{$recid} ? %{ $rec{$recid} } : () );
}

=item B<name>

Generic name of the instrument. (e.g. FE_A)

=cut

sub name {
  my $self = shift;
  if (@_) {
    $self->{NAME} = shift;
  }
  return $self->{NAME};
}

=item B<serial>

Serial name of the instrument. (e.g. RxA3)

=cut

sub serial {
  my $self = shift;
  if (@_) {
    $self->{SERIAL} = shift;
  }
  return $self->{SERIAL};
}

=item B<bandwidth>

Full bandwidth of the instrument, in Hz.

=cut

sub bandwidth {
  my $self = shift;
  if (@_) {
    $self->{BW} = shift;
  }
  return $self->{BW};
}

=item B<wavelength>

Approximate wavelength of the instrument band, in microns.

=cut

sub wavelength {
  my $self = shift;
  if (@_) {
    $self->{WAVELENGTH} = shift;
  }
  return $self->{WAVELENGTH};
}

=item B<focal_station>

Location of the instrument.

  DIRECT - in the cabin
  NASMYTH_L - left Nasmyth platform
  NASYMTH_R - right Nasymth platform

=cut

sub focal_station {
  my $self = shift;
  if (@_) {
    $self->{FOC_STATION} = uc(shift);
  }
  return $self->{FOC_STATION};
}

=item B<if_center_freq>

IF frequency.

=cut

sub if_center_freq {
  my $self = shift;
  if (@_) {
    $self->{IF_CENTER_FREQ} = shift;
  }
  return $self->{IF_CENTER_FREQ};
}

=item B<position>

X and Y Position of the instrument in the focal plane.

 ($x, $y) = $ins->position;
 $ins->position($x, $y);

Units are arcsec.

=cut

sub position {
  my $self = shift;
  if (@_) {
    @{$self->{XYPOS}} = @_;
  }
  return @{$self->{XYPOS}};
}

=item B<pointing>

Hash containing the pointing model offsets (in arcsec) for this instrument.
Recognized parameters are: CA, IE

  %pnt = $ins->pointing;
  $ins->pointing( %pnt );

=cut

sub pointing {
  my $self = shift;
  if (@_) {
    my %in = @_;

    my %local = map { $_, undef } @POINTING_MODEL;

    # delete any unrecognized keys
    for my $k (keys %in ) {
      delete $in{$k} unless exists $local{$k};
    }
    %{ $self->{POINTING_OFF} } = %in;

  }
  return %{ $self->{POINTING_OFF} };
}


=item B<smu_offset>

X, Y and Z offsets of the SMU when using this instrument.

 ($x, $y, $z) = $ins->smu_offset;
 $ins->position($x, $y, $z);

Units are ???.

=cut

sub smu_offset {
  my $self = shift;
  if (@_) {
    @{$self->{SMU_OFF}} = @_;
  }
  return @{$self->{SMU_OFF}};
}

=item B<receptor_offset>

Returns the receptor position as an C<Astro::Coords::Offset> object.

  $off = $ins->receptor_offset( "H01" );

=cut

sub receptor_offset {
  my $self = shift;
  my $receptor = uc(shift);
  my %rec = $self->receptors;
  throw JAC::OCS::Config::Error::FatalError("Supplied receptor '$receptor' does not exist in this instrument configuration")
    unless exists $rec{$receptor};
  return new Astro::Coords::Offset( @{$rec{$receptor}->{xypos}},
				    system => 'FPLANE');
}

=item B<receptor_offsets>

Returns the array of receptor positions as a list of C<Astro::Coords::Offset>
objects.

  @off = $ins->receptor_offsets;

Only includes positions of receptors that are turned on.

If receptor names are specified as arguments, only those will be returned
(if they are turned on).

  @off = $ins->receptor_offsets( @receptor_names );

=cut

sub receptor_offsets {
  my $self = shift;
  my @requested = @_;

  # Receptor information
  my %rec = $self->receptors;

  # Create a hash copy that only has the receptors we are interested
  my %requested;
  if (@requested) {
    for my $r (@requested) {
      $requested{$r} = $rec{$r} if exists $rec{$r};
    }
  } else {
    %requested = %rec;
  }

  # Now extract the information
  my @offsets = map { new Astro::Coords::Offset( @{$_->{xypos}}, system => "FPLANE") } 
    grep { $_->{health} ne 'OFF' } values %requested;

  return @offsets;
}

=item B<receptor_ids>

Returns the IDs of the receptors used in this instrument.

 @ids = $ins->receptor_ids;

=cut

sub receptor_ids {
  my $self = shift;
  my %rec = $self->receptors;
  return keys %rec;
}

=item B<working_receptor_ids>

Returns the IDs of the working receptors present on this instrument.

  @ids = $ins->working_receptor_ids;

=cut

sub working_receptor_ids {
  my $self = shift;

  my %rec = $self->receptors;
  my @working;
  for my $r (keys %rec) {
    push(@working, $r) if $rec{$r}->{health} ne "OFF";
  }
  return @working;
}

=item B<stringify>

Create XML representation of object.

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';

  $xml .= "<". $self->getRootElementName . " NAME=\"".$self->name."\"\n";
  $xml .= "            SERIAL=\"".$self->serial."\"\n" if $self->serial;
  $xml .= "            FOC_STATION=\"".$self->focal_station."\"\n";
  my @xy = $self->position;
  $xml .= "            X=\"".$xy[0]."\"\n";
  $xml .= "            Y=\"".$xy[1]."\"\n";
  $xml .= "            WAVELENGTH=\"".$self->wavelength."\"\n";
  $xml .= ">\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  $xml .= "<IF_CENTER_FREQ>". $self->if_center_freq .
    "</IF_CENTER_FREQ>\n";

  # MHz is a natural unit for bandwidth so multiply by 1E-6
  # Using unit class in the off chance that I begin storing the
  # bandwidth as an object with associated unit
  my $u = new JAC::OCS::Config::Units('Hz');
  $xml .= "<bw units=\"MHz\" value=\"".($self->bandwidth * $u->mult('M'))
    ."\" />\n";
  my @smu = $self->smu_offset;
  $xml .= "<smu_offset X=\"$smu[0]\" Y=\"$smu[1]\" Z=\"$smu[2]\" />\n";

  # pointing is optional
  my %pointing_offset = $self->pointing;
  if (keys %pointing_offset) {
    $xml .= "<pointing_offset ";
    for my $p (@POINTING_MODEL) {
      my $val = (exists $pointing_offset{$p} ? $pointing_offset{$p} : 0.0 );
      $xml .= "$p=\"$val\" ";
    }
    $xml .= "/>\n";
  }

  my %rec = $self->receptors;
  for my $r (keys %rec) {
    $xml .= "<receptor id=\"$r\"\n";
    $xml .= "          health=\"$rec{$r}{health}\"\n";
    my @xy = @{ $rec{$r}->{xypos}};
    $xml .= "          x=\"$xy[0]\"\n";
    $xml .= "          y=\"$xy[1]\"\n";
    $xml .= "          pol_type=\"$rec{$r}{pol_type}\" >\n";

    my $refpix = $rec{$r}{refpix};
    if (!exists $rec{$refpix}) {
      throw JAC::OCS::Config::Error::FatalError("Reference pixel ($refpix) is not available to this instrument configuration");
    }

    $xml .= "<sensitivity reference=\"$refpix\"\n";
    $xml .= "             value=\"$rec{$r}{sensitivity}\" />\n";

    $xml .= "<angle units=\"rad\" value=\"".$rec{$r}{angle}->radians."\" />\n";

    $xml .= "</receptor>\n";
  }


  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 General Methods

=over 4

=item B<footprint_radius>

Returns the effective centre position and radius of a circle that would
encompass all receptors in the receiver.

 $radius = $inst->footprint_radius;
 ($xcen, $ycen, $radius) = $inst->footprint_radius;

In scalar context returns just the radius. In list context returns the "centre"
coordinate of the circle.

Will not include disabled receptors.

Results are returned as Astro::Coord::Angle object.

=cut

sub footprint_radius {
  my $self = shift;

  my @positions = $self->receptor_offsets;

  # Get the max/min x and y coordinates
  my ($maxx, $minx, $miny, $maxy);

  my @xy = $positions[0]->offsets;
  $maxx = $minx = $xy[0];
  $maxy = $miny = $xy[1];

  for my $p (@positions) {
    @xy = $p->offsets;

    $maxx = $xy[0] if $xy[0] > $maxx;
    $maxy = $xy[1] if $xy[1] > $maxy;
    $minx = $xy[0] if $xy[0] < $minx;
    $miny = $xy[1] if $xy[1] < $miny;
  }

  # Find the centre of the circle
  my $xcen = ( $maxx + $minx ) / 2;
  my $ycen = ( $maxy + $miny ) / 2;

  # radius
  my $rad = sqrt( ($maxy - $ycen)**2 + ($maxx - $xcen)**2  );

  if (wantarray) {
    return map { new Astro::Coords::Angle($_, units => 'rad')} ($xcen, $ycen, $rad);
  } else {
    return new Astro::Coords::Angle($rad, units => 'rad');
  }
}

=item B<reference_receptor>

Retrieve the reference receptor.

 $ref = $ins->reference_receptor;
 @ref = $ins->reference_receptor;

Receiver W will return multiple reference pixels since there is no way to indicate
which waveband is required.

In scalar context retrieves an arbitrary reference if more than one is available.

=cut

sub reference_receptor {
  my $self = shift;
  my %rec = $self->receptors;

  # Working receptors only
  my @working = $self->working_receptor_ids;

  my %ref;
  for my $r (@working) {
    $ref{$rec{$r}->{refpix}}++;
  }

  my @refs = keys %ref;
  if (wantarray) {
    return @refs;
  } else {
    return $refs[0];
  }
}

=item B<contains_id>

Returns true if the supplied receptor ID is available on this
instrument. Otherwise false.

=cut

sub contains_id {
  my $self = shift;
  my $query = uc( shift );
  my %rec = $self->receptors;
  return ( exists $rec{$query} ? 1 : 0 );
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the Instrument config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "INSTRUMENT" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the Instrument XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  my %attr = find_attr( $el, "NAME","SERIAL","FOC_STATION","X","Y","WAVELENGTH");

  $self->name($attr{NAME});
  $self->serial($attr{SERIAL});
  $self->focal_station( $attr{FOC_STATION});
  $self->position( $attr{X}, $attr{Y});
  $self->wavelength( $attr{WAVELENGTH} );

  my $if = get_pcdata( $el, "IF_CENTER_FREQ");
  $self->if_center_freq( $if );

  my $child = find_children( $el, "bw", min=>1,max=>1);
  my %bwinfo = find_attr($child, "units","value");

  # simple unit parsing
  my $mult = 1;
  if (exists $bwinfo{units}) {
    my $u = JAC::OCS::Config::Units->new( $bwinfo{units} );
    if (defined $u) {
      $mult = $u->mult( '' );
    } else {
      warn "Unable to parse units '$bwinfo{units} in Instrument\n";
    }
  }
  $self->bandwidth( $bwinfo{value} * $mult );

  $child = find_children( $el, "smu_offset", min=>1,max=>1);
  my %smu = find_attr($child, "X","Y","Z");
  $self->smu_offset( @smu{"X","Y","Z"});

  $child = find_children( $el, "pointing_offset", max=>1);
  if (defined $child) {
    my %pnt = find_attr( $child, @POINTING_MODEL );
    $self->pointing( %pnt ) if keys %pnt;
  }

  # now process the receptor info
  my @r = find_children( $el, "receptor", min => 1);

  my %receptor;
  for my $r (@r) {
    my %attr = find_attr( $r, "id","health","x","y","pol_type","band");
    my $child = find_children($r,"sensitivity",min=>1,max=>1);
    my %sens = find_attr($child, "reference","value");
    $child = find_children($r,"angle",min=>1,max=>1);
    my %ang = find_attr($child,"units","value");

    $receptor{$attr{id}} = {
			    health => $attr{health},
			    xypos => [
				      $attr{x},$attr{"y"}
				     ],
			    pol_type => $attr{pol_type},
			    refpix => $sens{reference},
						     sensitivity => $sens{value},
			    angle => new Astro::Coords::Angle($ang{value},
							      units => $ang{units}),
			    band => $attr{band},
			   };

  }

  $self->receptors(%receptor);

  return;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The Instrument XML specification is documented in OCS/ICD/004 with a
DTD available at
http://www.jach.hawaii.edu/JACdocs/JCMT/OCS/ICD/012/instrument.dtd.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright 2004-2005 Particle Physics and Astronomy Research Council.
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
