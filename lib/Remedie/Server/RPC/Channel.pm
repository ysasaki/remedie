package Remedie::Server::RPC::Channel;
use Moose;
use Remedie::DB::Channel;
use Remedie::Worker;
use Feed::Find;

BEGIN { extends 'Remedie::Server::RPC' };

__PACKAGE__->meta->make_immutable;

no Moose;

sub load {
    my($self, $req, $res) = @_;
    my $channels = Remedie::DB::Channel::Manager->get_channels;
    return { channels => $channels };
}

sub create : POST {
    my($self, $req, $res) = @_;

    my $uri = $req->param('url');

    # TODO make this pluggable
    $uri = normalize_uri($uri);
    warn $uri;
    my @feeds = Feed::Find->find($uri);
    unless ($feeds[0]) {
        die "Can't find any feed in $uri";
    }

    my $feed_uri = $feeds[0]->as_string;

    my $channel = Remedie::DB::Channel->new;
    $channel->ident($feed_uri);
    $channel->type( Remedie::DB::Channel->TYPE_FEED );
    $channel->name($feed_uri);
    $channel->parent(0);
    $channel->save;

    return { channel => $channel };
}

sub refresh : POST {
    my($self, $req, $res) = @_;

    my $channel = Remedie::DB::Channel->new( id => $req->param('id') )->load;
    Remedie::Worker->work_channel($channel);

    $channel->load; # reload

    return { success => 1, channel => $channel };
}

sub show {
    my($self, $req, $res) = @_;

    my $channel = Remedie::DB::Channel->new( id => $req->param('id') )->load;

    return {
        channel => $channel,
        items   => $channel->items,
    };
}

sub update_status : POST {
    my($self, $req, $res) = @_;

    my $id      = $req->param('id');
    my $item_id = $req->param('item_id');
    my $status  = $req->param('status');

    my $enum = do {
        my $meth = "STATUS_" . uc $status;
        Remedie::DB::Item->$meth;
    };

    my $items;
    if ($id) {
        my $channel = Remedie::DB::Channel->new( id => $id )->load;
        $items = $channel->items;
    } else {
        my $item = Remedie::DB::Item->new( id => $item_id )->load;
        $id    = $item->channel_id;
        $items = [ $item ];
    }

    for my $item (@$items) {
        $item->status($enum);
        $item->save;
    }

    my $channel = Remedie::DB::Channel->new( id => $id )->load;
    return { channel => $channel, success => 1 };
}

sub normalize_uri {
    my $uri = shift;
    $uri =~ s/^feed:/http:/;
    $uri = "http://$uri" unless $uri =~ m!^https?://!;

    return URI->new($uri)->canonical;
}

1;
