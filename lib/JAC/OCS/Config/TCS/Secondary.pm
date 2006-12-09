package JAC::OCS::Config::TCS::Secondary;

=head1 NAME

JAC::OCS::Config::TCS::Secondary - Parse and modify TCS observing area

=head1 SYNOPSIS

  use JAC::OCS::Config::TCS::Secondary;

  $cfg = new JAC::OCS::Config::TCS::Secondary( File => 'Secondary.ent');
  $cfg = new JAC::OCS::Config::TCS::Secondary( XML => $xml );
  $cfg = new JAC::OCS::Config::TCS::Secondary( DOM => $dom );

  $pa       = $cfg->posang;
  %c       = $cfg->chop;

=head1 DESCRIPTION

This class can be used to parse and modify the telescope observing area
XML.

A SECONDARY element can contain a JIGGLE, CHOP or JIGGLE_CHOP
element, or no element at all.

A CHOP contains THROW and PA

A JIGGLE contains a PA

A JIGGLE_CHOP contains JIGGLE, CHOP and TIMING

Which means that we know we are JIGGLE_CHOP if we have both a JIGGLE
and a CHOP.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use warnings::register;
use XML::LibXML;
use Data::Dumper;

use Astro::Coords::Angle;
use JCMT::SMU::Jiggle;

use JAC::OCS::Config::Error;
use JAC::OCS::Config::Helper qw/ check_class_fatal /;
use JAC::OCS::Config::XMLHelper qw/ find_children find_attr get_pcdata 
				    get_this_pcdata indent_xml_string
				    /;
use JAC::OCS::Config::TCS::Generic qw/ find_pa find_offsets pa_to_xml /;

use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new Secondary configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::Secondary( File => $file );
  $cfg = new JAC::OCS::Config::Secondary( XML => $xml );
  $cfg = new JAC::OCS::Config::Secondary( DOM => $dom );

The constructor will locate the Secondary configuration in 
a C<< SECONDARY >> element. It will not attempt to verify that it has
a C<< TCS_CONFIG >> element as parent.

The method will return an unconfigured object if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options
  return $self->SUPER::new( @_,
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								    CHOP => {},
								    TIMING => {},
								    JIGGLE => undef,
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<tasks>

Return the name of the OCS tasks requiring this configuration.

 @task = $smu->tasks();

Always returns 'SMUTASK'.

=cut

sub tasks {
  return ('SMU');
}

=item B<motion>

The MOTION attribute reflects how the secondary is adjusted for
temperature and position effects

=cut

sub motion {
  my $self = shift;
  if (@_) {
    $self->{MOTION} = shift;
  }
  return $self->{MOTION};
}

=item B<jiggle>

Specification of the jiggle pattern as a C<JCMT::SMU::Jiggle>
object.

  $jig = $smu->jiggle;
  $smu->jiggle( $jig );

=cut

sub jiggle {
  my $self = shift;
  if (@_) {
    $self->{JIGGLE} = check_class_fatal( "JCMT::SMU::Jiggle", shift);
  }
  return $self->{JIGGLE};
}

=item B<chop>

Specification of the chop throw. Recognized keys are SYSTEM,
THROW and PA. PA must be a C<Astro::Coords::Angle> object and
THROW is in arcsec.

  %c = $obs->chop();
  $obs->chop( %c );

=cut

# we do not have a chop object

sub chop {
  my $self = shift;
  if (@_) {
    my %args = @_;
    for my $k (qw/ SYSTEM THROW PA /) {
      $self->{CHOP}->{$k} = $args{$k};
    }
  }
  return %{ $self->{CHOP} };
}

=item B<timing>

If we are chopping and jiggling at the same time, this field
controls the relative time spent in each position.
Recognized keys are CHOPS_PER_JIG, or N_JIGS_ON and N_CYC_OFF
(the latter two being used if we are doing multiple jiggles
per chop).

  %t = $obs->timing();
  $obs->timing( %t );

If CHOPS_PER_JIG > 0 we are in chop_jiggle mode else we are
in jiggle_chop mode.

=cut

# we do not have a timing object

sub timing {
  my $self = shift;
  if (@_) {
    my %args = @_;
    for my $k (qw/ CHOPS_PER_JIG N_JIGS_ON N_CYC_OFF /) {
      $self->{TIMING}->{$k} = $args{$k};
    }
  }
  return %{ $self->{TIMING} };
}

=item B<smu_mode>

The observing mode implemented by the secondary mirror.

  $mode= $smu->smu_mode();

Can be one of

   none
   chop
   jiggle
   jiggle_chop
   chop_jiggle

This mode is determined from the presence of CHOP and/or JIGGLE
specifications in the object.

Chop_jiggle can only be returned if timing parameters are available,
else "jiggle_chop" is returned if CHOP and JIGGLE settings exist.

=cut

sub smu_mode {
  my $self = shift;
  my %c = $self->chop;
  my $j = $self->jiggle;

  my $mode;
  if (%c && $j) {
    # Do we have timing
    my %timing = $self->timing;
    if (exists $timing{CHOPS_PER_JIG} && defined $timing{CHOPS_PER_JIG}
       && $timing{CHOPS_PER_JIG} > 0) {
      $mode = 'chop_jiggle';
    } else {
      $mode = 'jiggle_chop';
    }
  } elsif (%c) {
    $mode = "chop";
  } elsif ($j) {
    $mode = "jiggle";
  } else {
    $mode = "none";
  }
  return $mode;
}

=item B<stringify>

Convert the class into XML form. This is either achieved simply by
stringifying the DOM tree (assuming object content has not been
changed) or by taking the object attributes and reconstructing the XML.

 $xml = $sec->stringify;

=cut

sub stringify {
  my $self = shift;
  my %args = @_;
  my $xml = "";

  # motion
  $xml .= "<". $self->getRootElementName ." ";
  my $mo = $self->motion;
  $xml .= "MOTION=\"$mo\"" if defined $mo;
  $xml .= ">\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  # Obs mode
  my $mode = $self->smu_mode;

  if ($mode ne "none") {
    if ($mode eq 'jiggle_chop' || $mode eq 'chop_jiggle') {
      $xml .= "<JIGGLE_CHOP>\n";
    }

    if ($mode eq 'jiggle' || $mode eq 'jiggle_chop' || $mode eq 'chop_jiggle') {
      my $j = $self->jiggle;
      throw JAC::OCS::Config::Error::FatalError("We have a jiggle configuration ($mode) but no jiggle information!\n") unless defined $j;
      $xml .= "<JIGGLE NAME=\"".$j->name ."\"\n";
      $xml .= "        SYSTEM=\"". $j->system ."\"\n";
      $xml .= "        SCALE=\"". $j->scale ."\"\n";
      $xml .= ">\n";

      $xml .= pa_to_xml( $j->posang );
      $xml .= "</JIGGLE>\n";
    }

    if ($mode eq 'chop' || $mode eq 'jiggle_chop' || $mode eq 'chop_jiggle') {
      my %c = $self->chop;
      $xml .= "<CHOP SYSTEM=\"$c{SYSTEM}\" >\n";
      $xml .= "<THROW>$c{THROW}</THROW>\n";
      $xml .= pa_to_xml( $c{PA} );
      $xml .= "</CHOP>\n";
    }

    if ($mode eq 'jiggle_chop' || $mode eq 'chop_jiggle') {
      my %t = $self->timing;
      $xml .= "<TIMING>\n";
      if (exists $t{CHOPS_PER_JIG} && defined $t{CHOPS_PER_JIG}) {
	$xml .= "<CHOPS_PER_JIG>$t{CHOPS_PER_JIG}</CHOPS_PER_JIG>\n";
      } elsif (exists $t{N_JIGS_ON} && defined $t{N_JIGS_ON} &&
	       exists $t{N_CYC_OFF} && defined $t{N_CYC_OFF}) {
	$xml .= "<JIGS_PER_CHOP N_JIGS_ON=\"$t{N_JIGS_ON}\"\n";
	$xml .= "               N_CYC_OFF=\"$t{N_CYC_OFF}\" />\n";
      } else {
	warnings::warnif( "No timing information for SMU\n" );
      }
      $xml .= "</TIMING>\n";
      $xml .= "</JIGGLE_CHOP>\n";
    }

  }

  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the element that should be the root
node of the XML tree corresponding to the TCS Secondary config.

 @names = $tcs->getRootElementName;

=cut

sub getRootElementName {
  return( "SECONDARY" );
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

  # Get the motion
  $self->_find_motion();

  # Find the JIGGLE_CHOP
  $self->_find_jiggle_chop();

  # Find any JIGGLE if we did not find one in a jiggle chop
  $self->_find_jiggle() unless $self->jiggle;

  # Find a chop if we did not find one in a jiggle chop
  $self->_find_chop() unless $self->chop;

  return;
}

=item B<_find_motion>

Find the MOTION attribute that reflects how it is adjusted for
temperature and position effects

=cut

sub _find_motion {
  my $self = shift;
  my $el = $self->_rootnode;
  my $m = $el->getAttribute( "MOTION" );
  $self->motion( $m ) if $m;
}

=item B<_find_jiggle_chop>

Find JIGGLE_CHOP parameters. A JIGGLE_CHOP includes both a
CHOP and JIGGLE element and also a TIMING element.

=cut

sub _find_jiggle_chop {
  my $self = shift;
  my $root = $self->_rootnode;

  # First look for a JIGGLE_CHOP
  my $jchop = find_children( $root, "JIGGLE_CHOP", min => 0, max => 1);
  if (defined $jchop) {
    # We must have a TIMING, JIGGLE and CHOP
    my $chop = _find_chop_gen($jchop, min=>1, max => 1 );
    $self->chop( %$chop );

    # jiggling
    my $jig = _find_jiggle_gen($jchop, min=>1, max => 1 );
    $self->jiggle( $jig );

    # timing
    my $timing = find_children($jchop, "TIMING", min=>1, max=>1 );
    my $cpj = find_children( $timing, "CHOPS_PER_JIG", min=>0,max=>1);
    my $jpc = find_children( $timing, "JIGS_PER_CHOP", min=>0,max=>1);
    my %timing;
    if ($cpj) {
      # just get the PCDATA
      $timing{CHOPS_PER_JIG} = get_this_pcdata($cpj);
      throw JAC::OCS::Config::Error::XMLBadStructure( "Timing indicates CHOPS_PER_JIG but no content available") unless defined $timing{CHOPS_PER_JIG};
    } elsif ($jpc) {
      # Attributes
      my %jpc = find_attr( $jpc, "N_CYC_OFF", "N_JIGS_ON");
      %timing = (%timing, %jpc);

    } else {
      throw JAC::OCS::Config::Error::XMLBadStructure("JIGGLE_CHOP must have either CHOPS_PER_JIG or JIGS_PER_CHOP defined");
    }
    $self->timing( %timing );

  }

}

=item B<_find_chop>

Find the top level chop parameters, if present.
Only relevant if we are not jiggling.

 $cfg->_find_chop();

Optionally takes hash arguments, overrding the range checks
and specifying a new root node. Called from C<_find_jiggle_chop>.
Allowed keys are "rootnode", "max", and "min".

=cut

sub _find_chop {
  my $self = shift;
  my $chop = _find_chop_gen($self->_rootnode, min=>0, max => 1 );
  $self->chop( %$chop ) if defined $chop;
  return;
}

=item B<_find_jiggle>

Find the top level jiggle parameters, if present.
Only relevant if we are not also chopping.

Optionally takes a node as argument, superceeding the
default root node.

=cut

sub _find_jiggle {
  my $self = shift;
  my $jig = _find_jiggle_gen($self->_rootnode, min=>0, max => 1 );
  $self->jiggle( $jig ) if defined $jig;
  return;
}

=item B<_find_chop_gen>

Generic routine to find CHOP elements as children and extract
information. Return the chop information as a list of reference to
hashes. No objects for CHOPs.

 @chop = _find_chop_gen( $el );

The number of chops found can be verified if optional
hash arguments are provided. An exception will be thrown if the
number found is out of range. See also C<XMLHelper::find_children>.

 @chop = _find_chop_gen( $rootnode, min => 1, max => 4 );

In scalar context returns the first chop.

Called in two places from the constructor depending on whether we 
are jiggling and chopping or just chopping.

=cut

sub _find_chop_gen {
  my $el = shift;
  my %range = @_;

  # look for children called CHOP
  # but disable range check until we know how many valid ones we find
  my @matches = find_children( $el, "CHOP", %range );

  # Now iterate over all matches
  my @chops;
  for my $o (@matches) {
    my %chop;
    $chop{THROW}  = get_pcdata( $o, "THROW" );
    $chop{SYSTEM} = find_attr( $o, "SYSTEM" );
    $chop{PA}     = find_pa( $o, min => 1, max => 1 );
    push(@chops, \%chop);
  }

  # Check count
  return (wantarray ? @chops : $chops[0] );
}

=item B<_find_jiggle_gen>

Generic routine to find JIGGLE elements as children and extract
information. Return the jiggle information as a list of reference to
C<JCMT::SMU::Jiggle> objects.

 @jig = _find_jiggle_gen( $el );

The number of jiggles found can be verified if optional
hash arguments are provided. An exception will be thrown if the
number found is out of range. See also C<XMLHelper::find_children>.

 @jig = _find_jiggle_gen( $rootnode, min => 1, max => 4 );

In scalar context returns the first jiggle.

Called in two places from the constructor depending on whether we 
are jiggling and chopping or just jiggling.

=cut

sub _find_jiggle_gen {
  my $el = shift;
  my %range = @_;

  # look for children called CHOP
  my @matches = find_children( $el, "JIGGLE", %range );

  # Now iterate over all matches
  my @jiggles;
  for my $o (@matches) {
    my %jig = find_attr( $o, "SYSTEM", "SCALE", "NAME" );
    $jig{PA} = find_pa( $o, min => 1, max => 1);
    my $j = new JCMT::SMU::Jiggle();
    $j->name( $jig{NAME} );
    $j->system( $jig{SYSTEM} );
    $j->scale( $jig{SCALE} );
    $j->posang( $jig{PA} );

    push(@jiggles, $j);
  }

  return (wantarray ? @jiggles : $jiggles[0] );
}

=back

=end __PRIVATE_METHODS__

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
