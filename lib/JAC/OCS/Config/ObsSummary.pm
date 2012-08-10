package JAC::OCS::Config::ObsSummary;

=head1 NAME

JAC::OCS::Config::ObsSummary - Parse and modify OCS observation summary

=head1 SYNOPSIS

  use JAC::OCS::Config::ObsSummary;

  $cfg = new JAC::OCS::Config::ObsSummary( File => 'summary.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the observation summary
information present in the OBS_SUMMARY element of an OCS
configuration.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::XMLHelper qw(
				   indent_xml_string
				   get_pcdata
                                   find_children
                                   get_this_pcdata
				  );


use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = "1.01";

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new observation summary object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::ObsSummary( File => $file );
  $cfg = new JAC::OCS::Config::ObsSummary( XML => $xml );
  $cfg = new JAC::OCS::Config::ObsSummary( DOM => $dom );

The method will create a blank object if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
                            $JAC::OCS::Config::CfgBase::INITKEY => {
                                                                    IN_BEAM => [],
                                                                   }
                          );
}


=back

=head2 Accessor Methods

=over 4

=item B<mapping_mode>

Mapping mode associated with this observation.

  $mapmode = $obs->mapping_mode();

Usually one of 'scan', 'dream', 'stare', 'jiggle', or 'grid'

=cut

sub mapping_mode {
  my $self = shift;
  if (@_) {
    $self->{MAPPING_MODE} = shift;
  }
  return $self->{MAPPING_MODE};
}

=item B<switching_mode>

Switching mode associated with this observation.

  $swmode = $obs->switching_mode();

Usually one of 'none', 'pssw', 'chop', 'freqsw_slow', or 'freqsw_fast',
'self', 'spin'.

=cut

sub switching_mode {
  my $self = shift;
  if (@_) {
    $self->{SWITCHING_MODE} = shift;
  }
  return $self->{SWITCHING_MODE};
}

=item B<type>

The type of observation.

  $type = $obs->type();

Usually one of 'science', 'pointing', 'focus', 'skydip' or 'flatfield'.

=cut

sub type {
  my $self = shift;
  if (@_) {
    $self->{OBS_TYPE} = shift;
  }
  return $self->{OBS_TYPE};
}

=item B<inbeam>

Whether the observation requires some additional hardware to be
in the beam.

 @inbeam = $obs->inbeam();
 $obs->inbeam( @inbeam );

Returns first beam item in scalar context.

=cut

sub inbeam {
  my $self = shift;
  if (@_) {
    @{$self->{IN_BEAM}} = @_;
  }
  return (wantarray() ? @{$self->{IN_BEAM}} : $self->{IN_BEAM}->[0]);
}

=item B<comment>

Any comment associated with this summary.

 $comment = $obs->comment();

=cut

sub comment {
  my $self = shift;
  if (@_) {
    $self->{COMMENT} = shift;
  }
  return $self->{COMMENT};
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

  $xml .= "<mapping_mode>".
    (defined $self->mapping_mode ? $self->mapping_mode : '') 
    . "</mapping_mode>\n";
  $xml .= "<switching_mode>".
    (defined $self->switching_mode ? $self->switching_mode : '') 
    . "</switching_mode>\n";
  $xml .= "<obs_type>".
    (defined $self->type ? $self->type : '')
    . "</obs_type>\n";
  if ($self->inbeam) {
    $xml .= "<in_beam>" . $_ . "</in_beam>\n" foreach $self->inbeam();
  }
  $xml .= "<obs_comment>". $self->comment . "</obs_comment>"
    if $self->comment;

  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the observation summary.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "OBS_SUMMARY" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the summary XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  $self->mapping_mode( get_pcdata( $el, "mapping_mode") );
  $self->switching_mode( get_pcdata( $el, "switching_mode") );
  $self->type( get_pcdata( $el, "obs_type") );
  $self->comment( get_pcdata( $el, "comment") );

  my @in = ();
  foreach my $inbeam_element (find_children($el, 'in_beam')) {
    my $inbeam = get_this_pcdata($inbeam_element);
    $inbeam =~ s/^\s+//;
    $inbeam =~ s/\s+$//;
    push @in, split(/\s+/, $inbeam);
  }
  $self->inbeam( @in );

  return;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The Observation summary XML specification is documented in
OCS/ICD/021 with a DTD available at
http://docs.jach.hawaii.edu/JCMT/OCS/ICD/021/obs_summary.dtd.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright (C) 2008 Science and Technology Facilities Council.
Copyright 2005 Particle Physics and Astronomy Research Council.
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
