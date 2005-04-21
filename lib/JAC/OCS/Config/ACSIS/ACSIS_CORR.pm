package JAC::OCS::Config::ACSIS::ACSIS_CORR;

=head1 NAME

JAC::OCS::Config::ACSIS - Parse and modify OCS ACSIS correlator configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::ACSIS::ACSIS_CORR;

  $cfg = new JAC::OCS::Config::ACSIS::ACSIS_CORR( DOM => $dom);

=head1 DESCRIPTION

This class can be used to parse and modify the ACSIS correlator configuration
information present in the C<ACSIS_corr> element of an OCS configuration.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use warnings::register;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::XMLHelper qw(
                                   find_children
                                   find_attr
                                   indent_xml_string
                                  );

use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new ACSIS correlator configuration object. An object can be
created from a file name on disk, a chunk of XML in a string or a
previously created DOM tree generated by C<XML::LibXML> (i.e. A
C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::ACSIS_CORR( File => $file );
  $cfg = new JAC::OCS::Config::ACSIS_CORR( XML => $xml );
  $cfg = new JAC::OCS::Config::ACSIS_CORR( DOM => $dom );

A blank mapping can be created.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => {
								    BWMODES => [],
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<bw_modes>

The bandwidth modes, indexed by CM ID. Note that not all 32 elements will
necessarily have to be defined.

  @modes = $corr->bw_modes();
  $corr->bw_modes( @modes );


=cut

sub bw_modes {
  my $self = shift;
  if (@_) {
    my @modes = @_;
    warnings::warnif("More than 32 band width modes specified!")
      if $#modes > 31;
    @{ $self->{BWMODES} } = @modes;
  }
  return @{ $self->{BWMODES} };
}

=item B<stringify>

Create XML representation of object.

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';

  $xml .= "<ACSIS_corr>\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  # loop over the cm_map
  my @modes = $self->bw_modes;

  for my $cm_id (0..$#modes) {
    next unless defined $modes[$cm_id];
    $xml .= '<cm id="'. $cm_id . 
      '" bw_mode="' . $modes[$cm_id] . "\"/>\n";
  }

  # Fudge
  $xml .= '<rts_parms int_interval="50" timing_src="RTS_SOFT"/>' ."\n";

  # tidy up
  $xml .= "</ACSIS_corr>\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the ACSIS correlator config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "ACSIS_corr" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the ACSIS_corr XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  # All we have are map_id elements
  my @cm = find_children( $el, "cm", min => 1, max => 32 );

  my @bwmodes;
  for my $cmel (@cm) {
    my %attr = find_attr( $cmel, "id", "bw_mode");
    $bwmodes[$attr{id}] = $attr{bw_mode};
  }

  $self->bw_modes( @bwmodes );

  return;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The ACSIS XML configuration specification is documented in
OCS/ICD/005 with a DTD available at
http://www.jach.hawaii.edu/JACdocs/JCMT/OCS/ICD/005/acsis.dtd.

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
