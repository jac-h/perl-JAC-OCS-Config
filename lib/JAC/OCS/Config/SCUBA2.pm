package JAC::OCS::Config::SCUBA2;

=head1 NAME

JAC::OCS::Config::Frontend - Parse and modify OCS SCUBA-2 configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::SCUBA2;

  $cfg = new JAC::OCS::Config::Frontend( File => 'fe.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the frontend configuration
information present in the SCUBA2_CONFIG element of an OCS configuration.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::XMLHelper qw(
				   find_children
				   find_attr
				   indent_xml_string
				   get_pcdata_multi
				  );


use base qw/ JAC::OCS::Config::CfgBase JAC::OCS::Config::FEHelper /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d", q$Revision: 14392 $ =~ /(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new Frontend configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::SCUBA2( File => $file );
  $cfg = new JAC::OCS::Config::SCUBA2( XML => $xml );
  $cfg = new JAC::OCS::Config::SCUBA2( DOM => $dom );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								    MASK => {},
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<tasks>

Task or tasks that will be configured from this XML.

 @tasks = $cfg->tasks;

=cut

sub tasks {
  my $self = shift;
  return "SCUBA2";
}

=item B<active_subarrays>

Retursn the list of active subarrays (those that are not "OFF").

=cut

sub active_subarrays {
  my $self = shift;
  return $self->_active_elements;
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

  # Mask
  $xml .= $self->_stringify_mask();

  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));

}

=back

=head2 Class Methods

=over 4

=item B<dtdrequires>

Returns the names of any associated configurations required for this
configuration to be used in a full OCS_CONFIG. The frontend requires
'instrument_setup'.

  @requires = $cfg->dtdrequires();

=cut

sub dtdrequires {
  return ('instrument_setup', 'header', 'obs_summary');
}

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the Frontend config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "SCUBA2_CONFIG" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the Frontend XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  # Mask
  $self->_process_mask();

  return;
}

=item B<_mask_xml_name>

Returns the string that is used to represent the mask information xml
element name. Returns "SUBARRAY"

=cut

sub _mask_xml_name {
  return "SUBARRAY";
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The SCUBA-2 XML configuration specification is documented in
SC2/SOF/IC200/001 with a DTD available at ???.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2008 Science and Technology Facilities Council.
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
