# {{{ BEGIN BPS TAGGED BLOCK
# 
# COPYRIGHT:
#  
# This software is Copyright (c) 1996-2004 Best Practical Solutions, LLC 
#                                          <jesse@bestpractical.com>
# 
# (Except where explicitly superseded by other copyright notices)
# 
# 
# LICENSE:
# 
# This work is made available to you under the terms of Version 2 of
# the GNU General Public License. A copy of that license should have
# been provided with this software, but in any event can be snarfed
# from www.gnu.org.
# 
# This work is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
# 
# 
# CONTRIBUTION SUBMISSION POLICY:
# 
# (The following paragraph is not intended to limit the rights granted
# to you to modify and distribute this software under the terms of
# the GNU General Public License and is only of importance to you if
# you choose to contribute your changes and enhancements to the
# community by submitting them to Best Practical Solutions, LLC.)
# 
# By intentionally submitting any modifications, corrections or
# derivatives to this work, or any other work intended for use with
# Request Tracker, to Best Practical Solutions, LLC, you confirm that
# you are the copyright holder for those contributions and you grant
# Best Practical Solutions,  LLC a nonexclusive, worldwide, irrevocable,
# royalty-free, perpetual, license to use, copy, create derivative
# works based on those contributions, and sublicense and distribute
# those contributions and any derivatives thereof.
# 
# }}} END BPS TAGGED BLOCK
#
package RT::IR;

our $VERSION = '2.5.7';

use 5.008003;
use warnings;
use strict;

use Business::Hours;
use Business::SLA;


# XXX: we push config metadata into RT, but we need
# need interface to load config options metadata from
# extensions in RT core

use RT::IR::Config;
RT::IR::Config::Init();

my @QUEUES = ('Incidents', 'Incident Reports', 'Investigations', 'Blocks');
my %QUEUES = map { lc($_) => $_ } @QUEUES;
my %TYPE = (
    'incidents'        => 'Incident',
    'incident reports' => 'Report',
    'investigations'   => 'Investigation',
    'blocks'           => 'Block',
);

=head1 FUNCTIONS

=head2 BusinessHours

Returns L<Business::Hours> object initilized with information from
the config file. See option 'BusinessHours'.

=cut

sub BusinessHours {
    my $bizhours = new Business::Hours;
    if ( RT->Config->Get('BusinessHours') ) {
        $bizhours->business_hours( %{ RT->Config->Get('BusinessHours') } );
    }

    return $bizhours;
}

=head2 DefaultSLA

TODO: Not yet described.

=cut

sub DefaultSLA {
    my $SLAObj = SLAInit();
    return $SLAObj->SLA( time );
}

=head2 SLAInit

Returns an object of L<Business::SLA> class or class defined in SLAModule
config option.

See also the following options: SLAModule, RTIR_CustomFieldsDefaults and SLA.

=cut

sub SLAInit {

    my $class = RT->Config->Get('SLAModule') || 'Business::SLA';

    my $SLAObj = $class->new();
    $SLAObj->SetInHoursDefault( RT->Config->Get('RTIR_CustomFieldsDefaults')->{'SLA'}{'InHours'} );
    $SLAObj->SetOutOfHoursDefault( RT->Config->Get('RTIR_CustomFieldsDefaults')->{'SLA'}{'OutOfHours'} );

    my $bh = RT::IR::BusinessHours();
    $SLAObj->SetBusinessHours($bh);

    my $SLA = RT->Config->Get('SLA');
    foreach my $key( keys %$SLA ) {
        if ( $SLA->{ $key } =~ /^\d+$/ ) {
            $SLAObj->Add( $key, ( BusinessMinutes => $SLA->{ $key } ) );
        } else {
            $SLAObj->Add( $key, %{ $SLA->{ $key } } );
        }
    }

    return $SLAObj;
}

=head2 OurQueue

=cut

sub OurQueue {
    my $self = shift;
    my $queue = shift;
    $queue = $queue->Name if ref $queue;
    return undef unless $queue;
    return '' unless $QUEUES{ lc $queue };
    return $TYPE{ lc $queue };
}

sub Types {
    my $self = shift;
    return values %TYPE;
}

=head2 TicketType

Returns type of a ticket. Takes either Ticket or Queue argument.
Both arguments could be objects or IDs, however, name of a queue
works too for Queue argument. If the queue argument is defined then
the ticket is ignored even if it's defined too.

=cut

sub TicketType {
    my %arg = ( Queue => undef, Ticket => undef, @_);

    if ( defined $arg{'Ticket'} && !defined $arg{'Queue'} ) {
        my $obj = RT::Ticket->new( $RT::SystemUser );
        $obj->Load( ref $arg{'Ticket'} ? $arg{'Ticket'}->id : $arg{'Ticket'} );
        $arg{'Queue'} = $obj->QueueObj->Name if $obj->id;
    }
    return undef unless defined $arg{'Queue'};

    return $TYPE{ lc $arg{'Queue'} } if !ref $arg{'Queue'} && $arg{'Queue'} !~ /^\d+$/;

    my $obj = RT::Queue->new( $RT::SystemUser );
    $obj->Load( ref $arg{'Queue'}? $arg{'Queue'}->id : $arg{'Queue'} );
    return $TYPE{ lc $obj->Name } if $obj->id;

    return undef;
}

=head2 States

Return sorted list of unique states for one, many or all RTIR queues.

Takes arguments 'Queue', 'Active' and 'Inactive'. By default returns
only active states. Queue can be an array reference to list several
queues.

Examples:

    States()
    States( Queue => 'Blocks' );
    States( Queue => [ 'Blocks', 'Incident Reports' ] );
    States( Active => 0, Inactive => 1 );

=cut

sub States {
    my %arg = ( Queue => undef, Active => 1, Inactive => 0, @_ );

    my @queues = !$arg{'Queue'} ? (@QUEUES)
        : ref $arg{'Queue'}? @{ $arg{'Queue'} } : ( $arg{'Queue'} );
    
    my @states;
    foreach my $name (@queues) {
        my $queue = RT::Queue->new($RT::SystemUser);
        $queue->Load($name);
        if ( $queue->id ) {
            push @states, $queue->Lifecycle->Valid('initial', 'active')
                if $arg{'Active'};
            push @states, $queue->Lifecycle->Inactive
                if $arg{'Inactive'};
        }
        else {
            $RT::Logger->error( "failed to load queue $name" );
        }

    }

    my %seen = ();
    return sort grep !$seen{$_}++, @states;
}

sub NewQuery {
    my $self = shift;
    my %args = (
        Queue => undef,
        states => undef,
        add_states => undef,
        @_,
    );
    my @states = ref $args{'states'}? @{ $args{'states'} } : ( $args{'states'} );
    @states = grep $_, @states;
    unless( @states ) {
        @states = RT::IR::States( %args );
    }

    my @add_states = ref $args{'add_states'}? @{ $args{'add_states'} } : ( $args{'add_states'} );
    my %seen = ();
    @states =  grep !$seen{$_}++, map lc, grep $_, @states, @add_states;

    my $query = join " OR ",
                map "'Status' = '$_'",
                @states;
    $query = "( $query )" if $query;
    return $query;
}


sub BaseQuery {
    my $self = shift;
    my %args = (
        Queue        => undef,
        Exclude      => undef,
        HasNoMember  => undef,
        NotMemberOf  => undef,
        MemberOf     => undef,
        Constituency => undef,
        @_
    );
    my $res = '';
    if ( $args{'Queue'} ) {
        $res = join ' OR ', map "Queue = '$_'", grep defined && length,
            ref $args{'Queue'} ? ( @{ $args{'Queue'} } ) : ( $args{'Queue'} );
        $res = '( $res )' if $res && $res =~ / OR /;
    }
    if ( my $t = $args{'Exclude'} ) {
        $res .= ' AND ' if $res;
        $res .= '('. join( ' AND ', map "id != '$_'", map int $_, ref $t? (@$t) : ($t) ) .')';
    }
    if ( my $t = $args{'HasNoMember'} ) {
        $res .= ' AND ' if $res;
        $res .= 'HasMember != '. (ref $t? $t->id : int $t);
    }
    if ( my $t = $args{'NotMemberOf'} ) {
        $res .= ' AND ' if $res;
        $res .= 'MemberOf != '. (ref $t? $t->id : int $t);
    }
    if ( my $t = $args{'MemberOf'} ) {
        $res .= ' AND ' if $res;
        $res .= 'MemberOf = '. (ref $t? $t->id : int $t);
    }
    if (
        my $t = $args{'Constituency'}
        and RT->Config->Get('_RTIR_Constituency_Propagation') eq 'reject'
    ) {
        unless ( ref $t ) {
            my $tmp = RT::Ticket->new( RT->SystemUser );
            $tmp->Load( $t );
            $t = $tmp;
        }
        $res .= ' AND ' if $res;
        $res .= "CustomField.{Constituency} = '". $t->FirstCustomFieldValue('Constituency') ."'";
    }
    return $res;
}

sub ChildrenQuery {
    my $self = shift;
    my %args = (
        @_
    );

    my @parts;
    push @parts, $self->NewQuery(
        Queue  => $args{'Queue'},
        states => $args{'States'},
        add_states => $args{'AddStates'},
    );
    push @parts, $self->BaseQuery( Queue => $args{'Queue'} );
    push @parts, "MemberOf = ". $args{'Ticket'}->id if $args{'Ticket'};

    return join " AND ", map "($_)", @parts;
}

sub GetCustomField {
    my $field = shift or return;
    return (__PACKAGE__->CustomFields( $field ))[0];
}

{ my %cache;
sub CustomFields {
    my $self = shift;
    my %arg = (
        Field => undef,
        Queue => undef,
        Ticket => undef,
        @_%2 ? (Field => @_) : @_
    );

# TODO cache doesn't work with rt 3.9
# t/customfields/defaults-on-linking.t will fail with cache on
# maybe because it's called too early somewhere?
# anyway, seems caching here is not a great idea
# as it will obstruct cf updates later?
#    unless ( keys %cache ) {
        foreach my $qname ( @QUEUES ) {
            my $type = TicketType( Queue => $qname );
            $cache{$type} = [];

            my $queue = RT::Queue->new( $RT::SystemUser );
            $queue->Load( $qname );
            unless ($queue->id) {
                $RT::Logger->error("Couldn't load queue '$qname'");
                delete $cache{$type};
                return;
            }

            my $cfs = RT::CustomFields->new( $RT::SystemUser );
            $cfs->LimitToLookupType( 'RT::Queue-RT::Ticket' );
            $cfs->LimitToQueue( $queue->id );
            while ( my $cf = $cfs->Next ) {
                push @{ $cache{$type} }, $cf;
            }
        }

        $cache{'Global'} = [];
        my $cfs = RT::CustomFields->new( $RT::SystemUser );
        $cfs->LimitToLookupType( 'RT::Queue-RT::Ticket' );
        $cfs->LimitToGlobal;
        while ( my $cf = $cfs->Next ) {
            push @{ $cache{'Global'} }, $cf;
        }
#    }

    my $type = TicketType( %arg );

    my @list;
    if ( $type ) {
        @list = (@{ $cache{'Global'} }, @{ $cache{$type} });
    } else {
        @list = (@{ $cache{'Global'} }, map @$_, @cache{values %TYPE});
    }

    if ( my $field = $arg{'Field'} ) {
        if ( $field =~ /\D/ ) {
            @list = grep lc $_->Name eq lc $field, @list;
        } else {
            @list = grep $_->id == $field, @list;
        }
    }

    return wantarray? @list : $list[0];
} }

{ my $cache;
sub HasConstituency {
    return $cache if defined $cache;

    my $self = shift;
    return $cache = $self->CustomFields('Constituency');
} }

sub DefaultConstituency {
    my $queue = shift;
    my $name = $queue->Name;

    my @values;

    my $queues = RT::Queues->new( $RT::SystemUser );
    $queues->Limit( FIELD => 'Name', OPERATOR => 'STARTSWITH', VALUE => "$name - " );
    while ( my $pqueue = $queues->Next ) {
        next unless $pqueue->HasRight( Principal => $queue->CurrentUser, Right => "ShowTicket" );
        push @values, substr $pqueue->__Value('Name'), length("$name - ");
    }
    my $default = RT->Config->Get('RTIR_CustomFieldsDefaults')->{'Constituency'} || '';
    return $default if grep lc $_ eq lc $default, @values;
    return shift @values;
}


use Hook::LexWrap;

if ( RT::IR->HasConstituency ) {
    # ACL checks for multiple constituencies

    require RT::Interface::Web::Handler;
    # flush constituency cache on each request
    wrap 'RT::Interface::Web::Handler::CleanupRequest', pre => sub {
        %RT::IR::ConstituencyCache = ();
        %RT::IR::HasNoQueueCache = ();
    };

    require RT::Record;
    # flush constituency cache on update of the custom field value for a ticket
    wrap 'RT::Record::_AddCustomFieldValue', pre => sub {
        return unless UNIVERSAL::isa($_[0] => 'RT::Ticket');
        $RT::IR::ConstituencyCache{$_[0]->id}  = undef;
    };

    require RT::Ticket;
    wrap 'RT::Ticket::ACLEquivalenceObjects', pre => sub {
        my $self = shift;

        my $queue = RT::Queue->new($RT::SystemUser);
        $queue->Load($self->__Value('Queue'));

        # We do this, rather than fall through to the orignal sub, as that
        # interacts poorly with our overloaded QueueObj below
        if ( $self->CurrentUser->id == $RT::SystemUser->id ) {
            $_[-1] =  [$queue];
            return;
        }
        if ( UNIVERSAL::isa( $self, 'RT::Ticket' ) ) {
            my $const = $RT::IR::ConstituencyCache{ $self->id };
            if (!$const || $const eq '_none' ) {
                my $systicket = RT::Ticket->new($RT::SystemUser);
                $systicket->Load( $self->id );
                $const = $RT::IR::ConstituencyCache{ $self->id } =
                    $systicket->FirstCustomFieldValue('Constituency')
                    || '_none';
            }
            return if $const eq '_none';
            return if $RT::IR::HasNoQueueCache{ $const };

            my $new_queue = RT::Queue->new($RT::SystemUser);
            $new_queue->LoadByCols(
                Name => $queue->Name . " - " . $const
            );
            unless ( $new_queue->id ) {
                $RT::IR::HasNoQueueCache{$const} = 1;
                return;
            }
            $_[-1] =  [$queue, $new_queue];
        } else {
            $RT::Logger->crit("$self is not a ticket object like I expected");
        }
    };
}

require RT::Ticket;

require RT::Action::AutoOpen;
{
    no warnings 'redefine';
    my $prepare = RT::Action::AutoOpen->can('Prepare');
    *RT::Action::AutoOpen::Prepare = sub {
        my $self = shift;
        return 1 if $self->TicketObj->QueueObj->Name eq 'Blocks';
        $self->$prepare(@_);
    };
}

if ( RT::IR->HasConstituency ) {
    # Queue {Comment,Correspond}Address for multiple constituencies

    wrap 'RT::Ticket::QueueObj', pre => sub {
        my $queue = RT::Queue->new($_[0]->CurrentUser);
        $queue->Load($_[0]->__Value('Queue'));
        $queue->{'_for_ticket'} = $_[0]->id;
        $_[-1] = $queue;
        return;
    };

    wrap 'RT::Queue::HasRight', pre => sub {
        return unless $_[0]->id;
        return if $_[0]->{'disable_constituency_right_check'};
        return if $_[0]->{'_for_ticket'};
        return unless $_[0]->__Value('Name') =~
            /^(Incidents|Incident Reports|Investigations|Blocks)$/i;

        my $name = $1;
        my %args = (@_[1..(@_-2)]);
        $args{'Principal'} ||= $_[0]->CurrentUser;

        my $queues = RT::Queues->new( $RT::SystemUser );
        $queues->Limit( FIELD => 'Name', OPERATOR => 'STARTSWITH', VALUE => "$name - " );
        my $has_right = $args{'Principal'}->HasRight(
            %args,
            Object => $_[0],
            EquivObjects => $queues->ItemsArrayRef,
        );
        $_[-1] = $has_right;
        return;
    };


    require RT::Queue;
    package RT::Queue;

    sub CorrespondAddress { GetQueueAttribute(shift, 'CorrespondAddress') }
    sub CommentAddress { GetQueueAttribute(shift, 'CommentAddress') }

    sub GetQueueAttribute {
        my $queue = shift;
        my $attr  = shift;
        if ( ( my $id = $queue->{'_for_ticket'} ) ) {
            my $const = $RT::IR::ConstituencyCache{$id};
            if (!$const || $const eq '_none' ) {
                my $ticket = RT::Ticket->new($RT::SystemUser);
                $ticket->Load($id);
                $const = $RT::IR::ConstituencyCache{$ticket->id}
                    = $ticket->FirstCustomFieldValue('Constituency') || '_none';
            }
            if ($const ne '_none' && !$RT::IR::HasNoQueueCache{$const} ) {
                my $new_queue = RT::Queue->new($RT::SystemUser);
                $new_queue->LoadByCols(
                    Name => $queue->Name . " - " . $const );
                if ( $new_queue->id ) {
                    my $val = $new_queue->_Value($attr) || $queue->_Value($attr);
                    $RT::Logger->debug("Overriden $attr is $val for ticket #$id according to constituency $const");
                    return $val;
                } else {
                    $RT::IR::HasNoQueueCache{$const} = 1;
                }
            }
        }
        return $queue->_Value($attr);
    }
}


if ( RT::IR->HasConstituency ) {
    # Set Constituency on Create

    require RT::Ticket;
    wrap 'RT::Ticket::Create', pre => sub {
        my $ticket = $_[0];
        my %args = (@_[1..(@_-2)]);

        # get out if there is constituency value in arguments
        my $cf = GetCustomField( 'Constituency' );
        return unless $cf && $cf->id;
        return if $args{ 'CustomField-'. $cf->id };

        # get out of here if it's not RTIR queue
        my $QueueObj = RT::Queue->new( $RT::SystemUser );
        if ( ref $args{'Queue'} eq 'RT::Queue' ) {
            $QueueObj->Load( $args{'Queue'}->Id );
        }
        elsif ( $args{'Queue'} ) {
            $QueueObj->Load( $args{'Queue'} );
        }
        else {
            return;
        }
        return unless $QueueObj->id;
        return unless $QueueObj->Name =~
            /^(Incidents|Incident Reports|Investigations|Blocks)$/i; 
        
        # fetch value
        my $value;
        if ( $args{'MIMEObj'} ) {
            my $tmp = $args{'MIMEObj'}->head->get('X-RT-Mail-Extension');
            if ( $tmp ) {
                chomp $tmp;
                $tmp = undef unless
                    grep lc $_->Name eq lc $tmp, @{ $cf->Values->ItemsArrayRef };
            }
            $value = $tmp;
            $RT::Logger->debug("Found Constituency '$tmp' in email") if $tmp;
        }
        $value ||= RT->Config->Get('RTIR_CustomFieldsDefaults')->{'Constituency'};
        return unless $value;

        my @res = $ticket->Create(
            %args,
            'CustomField-'. $cf->id => $value,
        );
        $_[-1] = \@res;
    };
}

#
eval "require RT::IR_Vendor";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/IR_Vendor.pm});
eval "require RT::IR_Local";
die $@ if ($@ && $@ !~ qr{^Can't locate RT/IR_Local.pm});

1;
