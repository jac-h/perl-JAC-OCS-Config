package JAC::OCS::Config::RTS;

=head1 NAME

JAC::OCS::Config::RTS - Parse and modify OCS RTS configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::RTS;

  $cfg = new JAC::OCS::Config::RTS( File => 'fe.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the RTS configuration
information present in the RTS_CONFIG element of an OCS configuration.

=cut

use 5.006;
use strict;
use Carp;
use warnings;
use XML::LibXML;

use JAC::OCS::Config::Error qw| :try |;

use JAC::OCS::Config::XMLHelper;
use JAC::OCS::Config::XMLHelper qw(
				   find_children
				   find_attr
				   indent_xml_string
				   get_pcdata_multi
				  );


use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d.%03d", q$Revision$ =~ /(\d+)\.(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new RTS configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::RTS( File => $file );
  $cfg = new JAC::OCS::Config::RTS( XML => $xml );
  $cfg = new JAC::OCS::Config::RTS( DOM => $dom );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<stTimeout>

Timeour (ms) waiting for the start of sequence.

=cut

sub stTimeout {
  my $self = shift;
  if (@_) {
    $self->{ST_TIMEOUT} = shift;
  }
  return $self->{ST_TIMEOUT};
}

=item B<sampTimeout>

Fraction of STEP_TIME, timeout wait for input during sequence.

=cut

sub sampTimeout {
  my $self = shift;
  if (@_) {
    $self->{SAMP_TIMEOUT} = shift;
  }
  return $self->{SAMP_TIMEOUT};
}

=item B<opmode>

RTS operation mode: 

 0 FIX_SAMP;
 1 FIX_ITG;
 2 SLAVE_EXTCLK

=cut

sub opmode {
  my $self = shift;
  if (@_) {
    $self->{OP_MODE} = shift;
  }
  return $self->{OP_MODE};
}

=item B<sequence>

Array of sequence variants.

  @seq = $rts->sequence();
  $rts->sequence( @seq );

Variants are stored as reference to an array of wait and put
declarations.  The wait/put declarations are represented as hashes
with keys name, input/output and value. "input" is used for wait declarations
and output is used for put declarations.

=cut

sub sequence {
  my $self = shift;
  if (@_) {
    @{$self->{SEQUENCE}} = @_;
  }
  return @{$self->{SEQUENCE}};
}

=item B<stringify>

Create XML representation of object.

=cut

sub stringify {
  my $self = shift;
  my %args = @_;

  my $xml = '';

  $xml .= "<RTS_CONFIG>\n";

  $xml .= "<stTimeout value=\"".$self->stTimeout."\" />\n";
  $xml .= "<sampTimeout value=\"".$self->sampTimeout."\" />\n";
  $xml .= "<opMode value=\"".$self->opmode."\" />\n";

  my @seq = $self->sequence;
  if (!@seq) {
    $xml .= "<Sequence />\n";
  } else {
    $xml .= "<Sequence size=\"".@seq."\">\n";

    my $counter = 0;
    for my $s (@seq) {
      $counter++;
      # Array of arrays
      $xml .= "<position num=\"$counter\">\n";
      for my $dec (@{$s}) {
	my $name = $dec->{name};
	my $input = $dec->{input};
	my $output = $dec->{output};
	my $value = $dec->{value};
	$xml .= "<$name ";
	if ($name =~ /^put/) {
	  $xml .= "output=\"$output\" ";
	} else {
	  $xml .= "input=\"$input\" ";
	}
	$xml .= " value=\"$value\" />\n";
      }
      $xml .="</position>\n";
    }

    $xml .= "</Sequence>\n";
  }

  $xml .= "</RTS_CONFIG>\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back

=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the RTS config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "RTS_CONFIG" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the RTS XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;

  my $child = find_children( $el, "stTimeout", min => 1, max => 1);
  $self->stTimeout( scalar find_attr($child, "value" ) );

  $child = find_children( $el, "sampTimeout", min => 1, max => 1);
  $self->sampTimeout( scalar find_attr($child, "value" ) );

  $child = find_children( $el, "opMode", min => 1, max => 1);
  $self->opmode( scalar find_attr($child, "value" ) );

  $child = find_children( $el, "Sequence", min => 1, max => 1);
  my $size = find_attr( $child, "size" );

  if ($size) {
    # we know how many we should find
    my @decl = find_children($child, "position", min => $size, max => $size);

    my @sequence;
    for my $d (@decl) {
      # need all the children starting with put or wait
      my @declarations;
      for my $c ($d->findnodes('.//*[contains(name(),"wait")]'),
		 $d->findnodes('.//*[contains(name(),"put")]'),
		) {
	my $name = $c->nodeName;
	my %attr = find_attr( $c, "output","value", "input");
	$attr{name}= $name;
	push(@declarations, \%attr);
      }
      push(@sequence, \@declarations);
    }
    $self->sequence( @sequence );
  }

  return;
}

=head1 XML SPECIFICATION

The RTS XML configuration specification is documented in
OCS/ICD/012 with a DTD available at
L<http://www.jach.hawaii.edu/JACdocs/JCMT/OCS/ICD/012/rts.dtd.dtd>.

=head1 AUTHOR

Tim Jenness E<lt>t.jenness@jach.hawaii.eduE<gt>

Copyright 2004 Particle Physics and Astronomy Research Council.
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
