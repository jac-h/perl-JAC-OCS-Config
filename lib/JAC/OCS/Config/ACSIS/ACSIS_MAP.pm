package JAC::OCS::Config::ACSIS::ACSIS_MAP;

=head1 NAME

JAC::OCS::Config::ACSIS - Parse and modify OCS ACSIS machine map configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::ACSIS::ACSIS_MAP;

  $cfg = new JAC::OCS::Config::ACSIS::ACSIS_MAP( DOM => $dom);

=head1 DESCRIPTION

This class can be used to parse and modify the ACSIS machine map configuration
information present in the C<ACSIS_map> element of an OCS configuration. This
is used to specify the mapping of receptor+DCM combination to a specific
spectral window.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::Helper qw/ check_class_fatal /;

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

Create a new ACSIS mapping object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::ACSIS_MAP( File => $file );
  $cfg = new JAC::OCS::Config::ACSIS_MAP( XML => $xml );
  $cfg = new JAC::OCS::Config::ACSIS_MAP( DOM => $dom );

A blank mapping can be created.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								    CM => [],
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<tasks>

Task or tasks that will be configured from this XML.

 @tasks = $map->tasks;

=cut

sub tasks {
  my $self = shift;

  my @cm = $self->cm_map;
  my $hw = $self->hw_map;
  throw JAC::OCS::Config::Error::FatalError( "Can not determine task list without a hardware mapping\n") unless defined $hw;

  # first get all the CM_IDs from this configuration
  my @cm_ids = map { $_->{CM_ID} } @cm;

  # now look at the hardware map and get the task numbers
  my %ctask = map { $_, undef } $hw->bycmid( "CorrTask", @cm_ids);

  # Task names are CORRTASKN
  return ( map { "CORRTASK$_"} sort keys %ctask);
}

=item B<hw_map>

The hardware mapping required to determine which correlator tasks are
associated with a particular CM_ID. This is required to correctly calculate
the tasks. This mapping is specified as an C<JCMT::ACSIS::HWMap> object.

  $hw = $map->hw_map;
  $map->hw_map( $hw );

=cut

sub hw_map {
  my $self = shift;
  if (@_) {
    $self->{HWMAP} = check_class_fatal( "JCMT::ACSIS::HWMap", shift);
  }
  return $self->{HWMAP};
}

=item B<cm_map>

Returns array of maps, indexed by cm_id, each of which is a reference to a
hash with keys CM_ID, DCM_ID, RECEPTOR and SPW_ID.

  @cm = $map->cm_map();

Can be used to set the mapping.

  $map->cm_map( @newmap );

=cut

sub cm_map {
  my $self = shift;
  if (@_) {
    @{$self->{CM}} = @_;
  }
  return @{ $self->{CM} };
}

=item B<stringify>

Create XML representation of object.

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';
  $xml .= "<". $self->getRootElementName . ">\n";

  # Version declaration
  $xml .= $self->_introductory_xml();

  # loop over the cm_map
  for my $cm ($self->cm_map) {
    $xml .= '<map_id cm_id="'. $cm->{CM_ID} . 
      '" dcm_id="' . $cm->{DCM_ID} .
      '" receptor_id="' . $cm->{RECEPTOR} .
      '" spw_id="' . $cm->{SPW_ID} ."\"/>\n";
  }

  # tidy up
  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the ACSIS machine map config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "ACSIS_map" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the ACSIS_map XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  # All we have are map_id elements
  my @map_id = find_children( $el, "map_id", min => 1 );

  my @map;
  for my $mapel (@map_id) {
    my %attr = find_attr( $mapel, "cm_id", "dcm_id", "receptor_id", "spw_id");

    push(@map, {
		CM_ID => $attr{cm_id},
		DCM_ID => $attr{dcm_id},
		RECEPTOR => $attr{receptor_id},
		SPW_ID => $attr{spw_id},
	       });
  }

  $self->cm_map( @map );

  return;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The ACSIS XML configuration specification is documented in
OCS/ICD/005 with a DTD available at
http://www.jach.hawaii.edu/JACdocs/JCMT/OCS/ICD/005/acsis.dtd.

=head1 SEE ALSO

C<JCMT::ACSIS::HWMap>, C<JAC::OCS::Config>

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
