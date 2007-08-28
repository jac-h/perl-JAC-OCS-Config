package JAC::OCS::Config::Header;

=head1 NAME

JAC::OCS::Config::Header - Parse and modify OCS HEADER configurations

=head1 SYNOPSIS

  use JAC::OCS::Config::Header;

  $cfg = new JAC::OCS::Config::Header( File => 'header.ent');

=head1 DESCRIPTION

This class can be used to parse and modify the header configuration
information present in the HEADER_CONFIG element of an OCS configuration.

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
				  );

use JAC::OCS::Config::Header::Item;

use base qw/ JAC::OCS::Config::CfgBase /;

use vars qw/ $VERSION /;

$VERSION = sprintf("%d", q$Revision$ =~ /(\d+)/);

=head1 METHODS

=head2 Constructor

=over 4

=item B<new>

Create a new HEADER configuration object. An object can be created from
a file name on disk, a chunk of XML in a string or a previously created
DOM tree generated by C<XML::LibXML> (i.e. A C<XML::LibXML::Element>).

  $cfg = new JAC::OCS::Config::Header( File => $file );
  $cfg = new JAC::OCS::Config::Header( XML => $xml );
  $cfg = new JAC::OCS::Config::Header( DOM => $dom );

The method will die if no arguments are supplied.

=cut

sub new {
  my $self = shift;

  # Now call base class with all the supplied options +
  # extra initialiser
  return $self->SUPER::new( @_, 
			    $JAC::OCS::Config::CfgBase::INITKEY => { 
								    ITEMS => [],
								   }
			  );
}

=back

=head2 Accessor Methods

=over 4

=item B<items>

Header items found in this configuration, in the order in which they
appear in the config file.

  @i = $h->items;
  $h->items( @i );

=cut

sub items {
  my $self = shift;
  if (@_) {
    @{$self->{ITEMS}} = @_;
  }
  return @{$self->{ITEMS}};
}

=item B<nitems>

Return the number of items in the header.

=cut

sub nitems {
  my $self = shift;
  return ( $#{$self->{ITEMS}} + 1 );
}

=item B<item>

Retrieve a specific Item object by index (if the argument looks like
an integer), by keyword, by keyword pattern (if qr// object) or by
code reference. 

 $item = $hdr->item( 5 );
 $item = $hdr->item( 'PROJECT' );
 @items = $hdr->item( 'COMMENT' );
 @items = $hdr->item( qr/CRVAL/ );

If a code reference is specified, it will be called once for
each item (with the item passed in as argument) and should return true or false
depending on whether the item matches.

 @items = $hdr->item( sub { $_[0]->method eq 'TRANSLATOR' } );

In list context returns an empty list if no match. In scalar context
returns the matching item, undef if no matches, or the first matching
item. In most cases only one item will match in the header. HISTORY
and COMMENT are the most common multiple matches.

If an index is specified the array items start counting at 0.

=cut

sub item {
  my $self = shift;
  my $arg = shift;
  return () unless defined $arg;

  if ($arg =~ /^[0-9]+$/) {
    if ($arg > -1 && $arg < $self->nitems) {
      my @items = $self->items;
      return $items[$arg];
    } else {
      return ();
    }
  } else {
    # String or regexp match
    my @items = $self->items;

    my @match;
    if (ref($arg) eq 'Regexp' ) {
      @match = grep { $_->keyword =~ $arg } @items;
    } elsif (ref($arg) eq 'CODE') {
      @match = grep { $arg->( $_ ) } @items;
    } else {
      @match = grep { $_->keyword eq $arg } @items;
    }

    return (wantarray ? @match : $match[0] );
  }
}


=item B<set_ocscfg_filename>

This method locates the special callback hint in the header
XML (getOCSCFG) or the FITS header OCSCFG itself, and forces the
value to be the supplied filename.

  $hdr->set_ocscfg_filename( $filename );

Usually called just before the file is written to disk.

=cut

sub set_ocscfg_filename {
  my $self = shift;
  my $filename = shift;
  my $magic = 'OCSCFG';

  # Looking either for keyword of OCSCFG or method getOCSFG
  my @items = $self->item( sub { 
			     ($_[0]->keyword eq $magic) ||
			       (defined $_[0]->method &&
				$_[0]->method eq "get$magic");
			   } );

  for my $i (@items) {
    $i->value( $filename );
    $i->source( undef ); # clear derived status
  }

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

  for my $i ($self->items) {

    $xml .= "<HEADER TYPE=\"" . $i->type . "\"\n";
    $xml .= "        KEYWORD=\"" . $i->keyword . "\"\n"
      unless ($i->type eq 'BLANKFIELD' || $i->type eq 'COMMENT');
    $xml .= "        COMMENT=\"" . $i->comment . "\"\n" 
     if (defined $i->comment);
    $xml .= "        VALUE=\"" . $i->value . "\" "
      unless $i->type eq 'BLANKFIELD';

    if ($i->source) {
      my @attr;
      $xml .= ">\n";
      if ($i->source eq 'DRAMA') {
	$xml .= "<DRAMA_MONITOR ";
	@attr = qw/ TASK PARAM EVENT MULT /;

	# task and param are mandatory
	if (!defined $i->task || !defined $i->param) {
	  throw JAC::OCS::Config::Error::FatalError( "One of task or param is undefined for keyword ". $i->keyword ." using DRAMA monitor");
	}

      } elsif ($i->source eq 'GLISH') {
	$xml .= "<GLISH_PARAMETER ";
	@attr = qw/ TASK PARAM EVENT /;

	# task and param are mandatory
	if (!defined $i->task || !defined $i->param) {
	  throw JAC::OCS::Config::Error::FatalError( "One of task or param is undefined for keyword ". $i->keyword ." using GLISH parameter");
	}

      } elsif ($i->source eq 'DERIVED') {
	$xml .= "<DERIVED ";
	@attr = qw/ TASK METHOD EVENT /;

	# task and method are mandatory
	if (!defined $i->task || !defined $i->method) {
	  throw JAC::OCS::Config::Error::FatalError( "One of task or method is undefined for keyword ". $i->keyword ." using derived header value");
	}

      } elsif ($i->source eq 'SELF') {
	$xml .= "<SELF ";
	@attr = qw/ PARAM ALT ARRAY BASE /;

	# param is mandatory
	if (!defined $i->param ) {
	  throw JAC::OCS::Config::Error::FatalError( "PARAM is undefined for keyword ". $i->keyword ." using internal header value");
	}


      } else {
	croak "Unrecognized parameter source '".$i->source;
      }
      for my $a (@attr) {
	my $method = lc($a);
	$xml .= "$a=\"" . $i->$method . '" ' if $i->$method;
      }
      $xml .= "/>\n";
      $xml .= "</HEADER>\n";
    } else {
      $xml .= "/>\n";
    }

  }

  $xml .= "</". $self->getRootElementName .">\n";
  return ($args{NOINDENT} ? $xml : indent_xml_string( $xml ));
}

=back


=head2 Class Methods

=over 4

=item B<getRootElementName>

Return the name of the _CONFIG element that should be the root
node of the XML tree corresponding to the Header config.

 @names = $h->getRootElementName;

=cut

sub getRootElementName {
  return( "HEADER_CONFIG" );
}

=back

=begin __PRIVATE_METHODS__

=head2 Private Methods

=over 4

=item B<_process_dom>

Using the C<_rootnode> node referring to the top of the Header XML,
process the DOM tree and extract all the coordinate information.

 $self->_process_dom;

Populates the object with the extracted results.

=cut

sub _process_dom {
  my $self = shift;

  # Find all the header items
  my $el = $self->_rootnode;
  my @items = find_children( $el, "HEADER", min => 1 );

  my @obj;
  for my $i (@items) {
    my %attr = find_attr( $i, "TYPE","KEYWORD","COMMENT","VALUE");

    my @drama = find_children( $i, "DRAMA_MONITOR", min =>0, max=>1);
    my @glish = find_children( $i, "GLISH_PARAMETER", min =>0, max=>1);
    my @derived = find_children( $i, "DERIVED", min =>0, max=>1);
    my @self = find_children( $i, "SELF", min =>0, max=>1);

    my %mon;
    if (@drama) {
      %mon = find_attr( $drama[0], "TASK", "PARAM", "EVENT", "MULT");
      $mon{SOURCE} = "DRAMA";
    } elsif (@glish) {
      %mon = find_attr( $glish[0], "TASK", "PARAM", "EVENT");
      $mon{SOURCE} = "GLISH";
    } elsif (@derived) {
      %mon = find_attr( $derived[0], "TASK", "METHOD", "EVENT");
      $mon{SOURCE} = "DERIVED";
    } elsif (@self) {
      %mon = find_attr( $self[0], "PARAM", "ALT", "ARRAY", "BASE");
      $mon{SOURCE} = "SELF";
    }

    # Now create object representation
    push(@obj, new JAC::OCS::Config::Header::Item(
						  %attr,
						  %mon,
						 ));

  }

  $self->items( @obj );

  return;
}

=back

=end __PRIVATE_METHODS__

=head1 XML SPECIFICATION

The Header XML configuration specification is documented in OCS/ICD/011
with a DTD available at
http://docs.jach.hawaii.edu/JCMT/OCS/ICD/011/headers.dtd.

=head1 SEE ALSO

L<JAC::OCS::Config>, L<Astro::FITS::Header>.

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
