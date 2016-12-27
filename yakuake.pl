#!/usr/bin/perl

=head1 NAME

yakuake.pl - Save and restore yakuake sessions

=head1 DESCRIPTION

Save and restore yakuake sessions.

=head1 SYNOPSIS

yakuake.pl [OPTION]

Options:

    -s file   save yakuake sessions to a file
    -l file   restore yakuake sessions from a file
    
Note:

To activate file path completion, put this script somewhere in "PATH" and then execute it

=cut

use strict;
use warnings;
use 5.010;
use Net::DBus;
use Data::Dumper;
use Config::Tiny; 
use Capture::Tiny ':all';
use List::MoreUtils qw( zip );
use Getopt::Long qw(:config auto_help pass_through);

sub check_yakuake {
    my $bus = shift;
    my $yakuake;

    my $dbus = $bus->get_service('org.freedesktop.DBus')->get_object('/org/freedesktop/DBus') or die "Can't get the DBus instance";
    my $service_names = $dbus->ListNames;
    foreach (sort @{ $service_names }) {
        if ($_ =~ /org\.kde\.yakuake/) {
            $yakuake = $_;
            last;
        }
    }
    return $yakuake;
}

sub get_yakuake_sessions {
    my ($bus, $yakuake) = @_;

    my $service     = $bus->get_service($yakuake);
    my $session_obj = $service->get_object('/yakuake/sessions');
    my $tab_obj     = $service->get_object('/yakuake/tabs');

    my $active_session = $session_obj->activeSessionId;
    my @sessions       = sort { $a <=> $b } split /,/, $session_obj->sessionIdList;
    my @ksessions      = get_ksession_ids($service);
    my %session_map    = zip @sessions, @ksessions;
    
    my @tabs;
    foreach my $tab_num (0 .. $#sessions) {
        my $session_id  = $tab_obj->sessionAtTab($tab_num);
        my $ksession_id = $session_map{$session_id};
        my $pid         = get_session_pid($service, $ksession_id);
        my $fgpid       = get_session_fgpid($service, $ksession_id);
        push @tabs, {
            active => $session_id == $active_session,
            title  => $tab_obj->tabTitle($session_id),
            cwd    => get_cwd($pid),
            cmd    => get_cmd($pid, $fgpid),
        }
    }
    return \@tabs;
}

sub get_session_pid {
    my ($service, $id) = @_;
    return $service->get_object('/Sessions/' . $id)->processId;
}

sub get_session_fgpid {
    my ($service, $id) = @_;
    return $service->get_object('/Sessions/' . $id)->foregroundProcessId;
}

sub get_ksession_ids {
    my $service = shift;
    return ( sort   { $a <=> $b }
             map    { m{ name = [\"] (\d+) [\"] }mx }
             grep   { m{ <node \s+ name }mx }
             split m{ \n }msx,
             $service->get_object('/Sessions')->Introspect );
}

sub get_cwd {
    my $pid = shift;
    my $cmd = 'pwdx ' . $pid;
    my $stdout = capture {system ($cmd)};
    return trim( (split /:/s, $stdout)[1] );
}

sub get_cmd {
    my ($pid, $fgpid) = @_;
    if ($pid == $fgpid) {
        return '';
    }
    else {
        my $cmd = 'ps --format command --no-headers --pid ' . $fgpid;
        my $stdout = capture {system ($cmd)};
        return trim($stdout);
    }
}

sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub save_to_config {
    my ($tabs, $file) = @_;
    $file ||= $ENV{"HOME"} . '/ysession.conf';

    my $config = Config::Tiny->new;
    my $num = 1;
    foreach my $tab (@$tabs) {
        my $section = 'Tab ' . $num;
        $config->{$section}->{title}  = $tab->{title};
        $config->{$section}->{active} = $tab->{active};
        $config->{$section}->{cwd}    = $tab->{cwd};
        $config->{$section}->{cmd}    = $tab->{cmd};
        $num++;
    }
    $config->write($file);
    say "The yakuake session config has been saved to: " . $file;
}

sub read_from_config {
    my $file = shift;
    return Config::Tiny->read($file);
}

sub load_yakuake_sessions {
    my ($bus, $yakuake, $config) = @_;

    my $active_id;
    my $service     = $bus->get_service($yakuake);
    my $session_obj = $service->get_object('/yakuake/sessions');
    my $tab_obj     = $service->get_object('/yakuake/tabs');

    foreach (sort keys %{$config}) {
        my $title  = $config->{$_}->{title};
        my $active = $config->{$_}->{active};
        my $cwd    = $config->{$_}->{cwd};
        my $cmd    = $config->{$_}->{cmd};

        $session_obj->addSession;
        my $new_session_id = $session_obj->activeSessionId;
        $tab_obj->setTabTitle($new_session_id, $title);
        $session_obj->runCommand('cd ' . $cwd);
        $session_obj->runCommand($cmd);
        $active_id = $new_session_id if ($active eq '1');
    }
    say $active_id;
    $session_obj->raiseSession($active_id);
}

sub show_sessions {
    my $tabs = shift;
    
    my $num = 1;
    foreach my $tab (@$tabs) {
        say '[Tab ' . $num . ']';
        say 'title = ' . $tab->{title};
        say 'active = ' . $tab->{active};
        say 'cwd = ' . $tab->{cwd};
        say 'cmd = ' . $tab->{cmd};
        say '';
        $num++;
    }
}

my $bus = Net::DBus->session;

my $yakuake = check_yakuake($bus);
if (! defined $yakuake) {
    say "Not found yakuake service on current bus.";
    exit;
}

my ($save, $load);
my $tabs = get_yakuake_sessions($bus, $yakuake);

GetOptions(
        's=s' => \$save,   
        'l=s' => \$load,
    );

if ($save) {
    say 'save config';
    save_to_config($tabs, $save);
}
elsif ($load) {
    say 'load config';
    my $config = read_from_config($load);
    load_yakuake_sessions($bus, $yakuake, $config);
}
else {
    show_sessions($tabs); 
}
