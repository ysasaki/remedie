package Remedie::Server::RPC::Channel;
use Any::Moose;
use Remedie::DB::Channel;
use Remedie::Updater;
use Template;
use Encode;
use DateTime::Format::ISO8601;
use DateTime::Format::Mail;
use Plagger::FeedParser;
use URI::Fetch;
use Coro;

BEGIN { extends 'Remedie::Server::RPC' };

__PACKAGE__->meta->make_immutable;

no Any::Moose;

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

    my $feed_uri;
    unless ($req->param('no_discovery')) {
        my $res = Plagger::UserAgent->new->fetch($uri);
        $feed_uri = Plagger::FeedParser->discover($res);
    }

    my $type = $feed_uri ? Remedie::DB::Channel->TYPE_FEED : Remedie::DB::Channel->TYPE_CUSTOM;
    my $channel_uri = $feed_uri || $uri;

    # TODO maybe prompt or ask plugin if $type is CUSTOM

    my $channel = Remedie::DB::Channel->new;
    $channel->ident($channel_uri);
    $channel->type($type);
    $channel->name($channel_uri);
    $channel->parent(0);
    $channel->save;

    return { channel => $channel };
}


sub update : POST {
    my($self, $req, $res) = @_;

    my $channel = Remedie::DB::Channel->new( id => $req->param('id') )->load;
    $channel->name( decode_utf8($req->param('name')) );
    $channel->save;

    return { channel => $channel };
}

sub refresh : POST {
    my($self, $req, $res) = @_;

    my @channel_id = $req->param('id');
    my $channels = Remedie::DB::Channel::Manager->search(id => \@channel_id);

    my @event_id;
    for my $channel (@$channels) {
        my $event_id = "event." . Time::HiRes::gettimeofday;
        async {
            my $updater = Remedie::Updater->new( conf => $self->conf );

            $updater->update_channel($channel, { clear_stale => scalar $req->param('clear_stale') })
                or die "Refreshing failed";

            $channel->load; # reload

            Remedie::PubSub->broadcast({ id => $event_id, success => 1, channel => $channel });
        };
        push @event_id, $event_id;
    }

    return \@event_id;
}

sub show {
    my($self, $req, $res) = @_;

    my $channel = Remedie::DB::Channel->new( id => $req->param('id') )->load;

    return {
        channel => $channel,
        items   => $channel->items(
            limit  => scalar $req->param('limit'),
            status => [ map _enum_status($_), $req->param('status') ],
        ),
    };
}

sub rss {
    my($self, $req, $res) = @_;

    my $channel = Remedie::DB::Channel->new( id => $req->param('id') )->load;
    my $items   = $channel->items;

    my $stash = {
        channel => $channel,
        items   => $items,
        to_rfc822 => sub {
            eval { DateTime::Format::Mail->format_datetime( DateTime::Format::ISO8601->parse_datetime(shift) ) };
        },
    };

    my $tt = Template->new;
    $tt->process(\<<TEMPLATE, $stash, \my $out) or die $tt->error;
<?xml version="1.0" encoding="utf-8"?>
<!-- Media RSS generated by Remedie [% version %] -->
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
  xmlns:media="http://search.yahoo.com/mrss/">
 <channel>
  <title>[% channel.name | html %]</title>
  <link>[% channel.props.link | html %]</link>
  <description>[% channel.props.description | html %]</description>
  <itunes:summary>[% channel.props.description | html %]</itunes:summary>
[%- IF channel.props.thumbnail %]
[%- SET thumb = channel.props.thumbnail %]
  <itunes:image href="[% thumb.url %]" />
  <image>
   <title>[% channel.name | html %]</title>
   <link>[% channel.props.link | html %]</link>
   <url>[% thumb.url | html %]</url>
  [%- IF thumb.width %]<width>[% thumb.width | html %]</width>[% END %]
  [%- IF thumb.height %]<height>[% thumb.height | html %]</height>[% END %]
  </image>
[%- END %]
[%- FOREACH item = items %]
  <item>
   <title>[% item.name | html %]</title>
   <link>[% item.props.link | html %]</link>
   <description>[% item.props.description | html %]</description>
   <itunes:subtitle>[% item.props.description | html %]</itunes:subtitle>
[%- IF item.props.updated %]
   <pubDate>[% to_rfc822(item.props.updated) %]</pubDate>
[%- END %]
   <guid isPermaLink="false">[% item.ident | html %]</guid>
   <enclosure url="[% item.ident | html %]" length="[% (item.props.size || -1) | html %]" type="[% item.props.type | html %]" />
   <media:content [% IF item.props.type && item.props.match('video/audio') %]medium="[% item.props.type.split('/').0 %]"[% END %] length="[% (item.props.size || -1) | html %]" url="[% item.ident | html %]" type="[% item.props.type | html %]" />
   <media:title>[% item.name | html %]</media:title>
   <media:description>[% item.props.description | html %]</media:description>
[%- IF item.props.thumbnail %]
[%- SET thumb = item.props.thumbnail -%]
   <media:thumbnail url="[% thumb.url | html %]" [% IF thumb.width %]width="[% thumb.width | html %]"[% END %] [% IF thumb.height %]height="[% thumb.height | html %]"[% END %] />
[%- END %]
[%- IF item.props.embed %]
   <media:player url="[% item.ident | html %]" [% IF item.props.embed.width %]width="[% item.props.embed.width | html %]"[% END %] [% IF item.props.embed.height %]height="[% item.props.embed.height | html %]"[% END %] />
[%- END %]
  </item>
[%- END %]
 </channel>
</rss>
TEMPLATE


    $res->status(200);
    $res->content_type("application/rss+xml; charset=utf-8");
    $res->content_type("text/xml");
    $res->body( encode_utf8($out) );

    return { success => 1 };
}

sub _enum_status {
    my $string = shift or return;

    my $meth = "STATUS_" . uc $string;
    Remedie::DB::Item->$meth;
}

sub update_status : POST {
    my($self, $req, $res) = @_;

    my $id      = $req->param('id');
    my $item_id = $req->param('item_id');
    my $status  = _enum_status($req->param('status'));

    my $items;
    if ($id) {
        my $channel = Remedie::DB::Channel->new( id => $id )->load;
        $items = $channel->items;
    } else {
        my $item = Remedie::DB::Item->new( id => $item_id )->load;
        $id    = $item->channel_id;

        # mark as watched will make other items with same ident watched as well
        if ($status == Remedie::DB::Item->STATUS_WATCHED) {
            $items = Remedie::DB::Item::Manager->get_items(
                query => [ ident => $item->ident ]
            );
        } else {
            $items = [ $item ];
        }
    }

    for my $item (@$items) {
        $item->status($status);
        $item->save;
    }

    my $channel = Remedie::DB::Channel->new( id => $id )->load;
    return { channel => $channel, success => 1 };
}

sub normalize_uri {
    my $uri = shift;

    # TODO this should be replaced with pluggable feed discovery
    my %is_known = map { $_ => 1 } qw ( http https file script );

    $uri = URI->new($uri);
    $uri->scheme("http") if $uri->scheme && $uri->scheme eq 'feed';
    $uri = URI->new("http://$uri") unless $is_known{$uri->scheme};

    return URI->new($uri)->canonical;
}

sub remove : POST {
    my($self, $req, $res) = @_;

    my $id      = $req->param('id');
    my $channel = Remedie::DB::Channel->new( id => $id )->load;
    my $items   = $channel->items;

    $channel->delete;

    # TODO remove local files if downloaded (optional)
    for my $item (@$items) {
        $item->delete;
    }

    return { success => 1, id => $id };
}

sub sort : POST {
    my($self, $req, $res) = @_;

    my $params = $req->parameters;
    while (my($id, $order) = each %$params) {
        my $channel = Remedie::DB::Channel->new(id => $id)->load
            or next;
        $channel->props->{order} = $order;
        $channel->save;
    }
}

1;
