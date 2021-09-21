package Gateway;

use warnings;
use strict;
use Carp;

use AnyEvent;
use AnyEvent::Impl::Perl;
use AnyEvent::Socket;
use AnyEvent::Handle;

my ( $tindex, %index, %server, %type ) = ( 0 );

sub new
{
    my ( $class, %this ) = @_;

    $this{port} ||= 9999;

    $0 = 'openc3.gateway';

    %type = %{$this{server}};
    map{ $server{$_} = 0 }keys %type;

    bless \%this, ref $class || $class;
}

sub clean 
{
    for my $index ( keys %index )
    {
        if( $index{$index}{handle_s} ) 
        {

            $index{$index}{handle_s}->destroy()
                if $index{$index}{handle_c}->destroyed() && ! $index{$index}{handle_s}->destroyed();

            $index{$index}{handle_c}->destroy()
                if ! $index{$index}{handle_c}->destroyed() && $index{$index}{handle_s}->destroyed();

 
            if( $index{$index}{handle_c}->destroyed() && $index{$index}{handle_s}->destroyed() )
            {
                 delete $index{$index};
                 map{ $server{$_} = 0 if $server{$_} == $index }keys %server;   
            }
        }
        else
        {
            delete $index{$index} if $index{$index}{handle_c}->destroyed();
        }
    }
}

sub getServer
{
    my ( $this, $type ) = @_;
    my @server = sort keys %server;
    my $i = $tindex;
    for my $k ( $i .. $i + @server )
    {
        $tindex ++;
        $k = $k % @server;
        my $server = $server[$k];
        return $server if $type{$server} == $type && $server{$server} == 0;
    }

    return;
}

sub allocate
{
    my $this = shift;

    $this->clean();
    my %t; map{ $t{$_} = 1 }values %type;

    for my $type ( keys %t )
    {
        my ( $idx ) = sort{ $a <=> $b }
             grep{ defined $index{$_}{handle_c_data_type} && $index{$_}{handle_c_data_type} == $type && ! $index{$_}{m} && $index{$_}{handle_c_data} }keys %index;
        next unless $idx;
        next unless my $server = $this->getServer( $type );

        printf "DEBUG: index: $idx, type: $type, datatype: %s $server HEAD:%s\n", $index{$idx}{handle_c_data_type},  $index{$idx}{handle_c_data};;
        $this->_allocate( $idx, $server, $type );
    }
}

sub showUrl
{
    my ( $this, $index ) = @_;

    return unless my $head = $index{$index}{handle_c_data};

    my ( $url ) = split /\n/, $head;
    $url =~ s/\r$//;

    print "GatewayUrl:$url\n";
}


sub showPool
{
    my $this = shift;

    my %t; map{ $t{$_} = 0 }values %type;
    for my $type ( keys %t )
    {
        $t{$type} = grep{ !$server{$_} }grep{ $type{$_} == $type  }keys %server;
    }
    printf "GatewayPool:%s\n", join " ", map{ "T:$_=$t{$_}" }sort keys %t;
}

sub _allocate
{
    my ( $this, $idx, $server ) = @_;


    my ( $host, $port ) = split /:/, $server;

    return if $index{$idx}{m};
    $index{$idx}{m} = time + 5;

    tcp_connect $host, $port, sub {
        my ( $fh, $tip, $tport ) = @_;

        my $index = $idx;
        my $srv = $server;
        unless( $fh )
        {
            print "tcp_connect $host:$port err $!\n";
            $server{$srv} = -15;
            return;
        }

        $server{$srv} = $index;

        $this->showPool();

        $index{$index}{server} = $srv;
        my $handle; $handle = new AnyEvent::Handle( 
            fh => $fh,
            keepalive => 1,
            rbuf_max => 1024000,
            wbuf_max => 1024000,
            autocork => 1,
            on_eof => sub{
               $index{$index}{handle_c}->destroy() unless $index{$index}{handle_c}->destroyed();
               $this->allocate();

            },
            on_read => sub {
                my $self = shift;
	        my $len = length $self->{rbuf};

                $self->push_read (
                    chunk => $len,
                    sub { 
                        $index{$index}{handle_c}->push_write($_[1]);
                        $index{$index}{sended} = 1;
                    }
                );
            },
            on_error => sub {
               $server{$srv} = -6;

               #错误时不要关闭客户端的连接，进行修复
               #如果服务端已经给客户端返回了一部分数据然后死掉的，没办法进行恢复了
               delete $index{$index}{handle_s};
               delete $index{$index}{m};

               $this->allocate();
             },
        );

        $handle->push_write($index{$index}{handle_c_data}) if $index{$index}{handle_c_data};
        $index{$index}{handle_s} = $handle;
    };
    return 1;
}

sub getType
{
    my ( $this, $index ) = @_;
    return unless my $data = $index{$index}{handle_c_data};

    if( $data =~ /Host: api\.connector\.open-c3\.org:80/ )
    {
        return 1 if $data =~ m#^\w+\s+/internal/#;
        return 0;
    }

    return 2 if $data =~ /Host: api\.job\.open-c3\.org:80/;
}

sub run
{
    my $this = shift;
    my $port = $this->{port};

    my ( $i, $cv ) = ( 0,  AnyEvent->condvar );

    tcp_server undef, $port, sub {
       my ( $fh, $tip, $tport ) = @_ or die "tcp_server: $!";

       my $index = ++$i;

       my $handle; $handle = new AnyEvent::Handle( 
           fh => $fh,
           keepalive => 1,
           rbuf_max => 1024000,
           wbuf_max => 1024000,
           autocork => 1,
           on_eof => sub{
               $index{$index}{handle_s}->destroy() if $index{$index}{handle_s} && ! $index{$index}{handle_s}->destroyed();

               $this->allocate();
           },
           on_read => sub {
               my $self = shift;
	       my $len = length $self->{rbuf};
               $self->push_read (
                   chunk => $len,
                   sub { 
                       $index{$index}{handle_c_data} .= $_[1];
                       
                       $index{$index}{handle_c_data_type} = $this->getType( $index );
                     
                       $this->showUrl( $index );

                       $index{$index}{handle_s}->push_write($_[1]) if $index{$index}{handle_s};

                       $this->allocate();
                   }
               );
           },
           on_error => sub {
               $index{$index}{handle_s}->destroy() if $index{$index}{handle_s} && ! $index{$index}{handle_s}->destroyed();

               $this->allocate();
            },
        );

        $index{$index}{handle_c} = $handle;

        $this->allocate();
    };

    my $ti = AnyEvent->timer(
        after => 1, 
        interval => 1,
        cb => sub { 
            $this->showPool();
            $this->allocate();

            my $time = time;
            map{ delete $index{$_}{m} if $index{$_}{m} && ! $index{$_}{handle_s} && $index{$_}{m} < $time; }keys %index;

            map{ $server{$_} ++ if $server{$_} < 0 }keys %server;
        }
    ); 

    $cv->recv;
}

1;
