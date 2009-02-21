# -*- mode: cperl;-*-

use Dpkg::IPC;
use File::Spec;
use Test::More;

use strict;
use warnings;

my $srcdir = $ENV{srcdir} || '.';
my $admindir = File::Spec->rel2abs("$srcdir/t.tmp/ua/admindir"),
my $altdir = File::Spec->rel2abs("$srcdir/t.tmp/ua/alternatives");
my $bindir = File::Spec->rel2abs("$srcdir/t.tmp/ua/bin");
# XXX: switch to version without .pl
my @ua = ("$srcdir/update-alternatives.pl", "--quiet", "--admindir",
	  "$admindir", "--altdir", "$altdir");

my $main_link = "$bindir/generic-test";
my $main_name = "generic-test";
my @choices = (
    {
	path => "/bin/true",
	priority => 20,
	slaves => [
	    {
		"link" => "$bindir/slave2",
		name => "slave2",
		path => "/bin/cat",
	    },
	    {
		"link" => "$bindir/slave1",
		name => "slave1",
		path => "/bin/yes",
	    },
	],
    },
    {
        path => "/bin/false",
        priority => 10,
        slaves => [
	    {
		"link" => "$bindir/slave1",
		name => "slave1",
		path => "/bin/date",
	    },
        ],
    },
    {
        path => "/bin/sleep",
        priority => 5,
        slaves => [],
    },
);
my $nb_slaves = 2;
plan tests => (4 * ($nb_slaves + 1) + 2) * 18 # number of check_choices
		+ 49;			      # rest

sub cleanup {
    system("rm -rf $srcdir/t.tmp/ua && mkdir -p $admindir && mkdir -p $altdir");
    system("mkdir -p $bindir/more");
}

sub call_ua {
    my ($params, %opts) = @_;
    fork_and_exec("exec" => [ @ua, @$params ], nocheck => 1,
		  wait_child => 1, env => { LC_ALL => "C" }, %opts);
    if ($opts{"expect_failure"}) {
	ok($? != 0, "update-alternatives @$params did not fail.");
    } else {
	ok($? == 0, "update-alternatives @$params failed.");
    }
}

sub install_choice {
    my ($id, %opts) = @_;
    my $alt = $choices[$id];
    my @params = ("--install", "$main_link", "$main_name",
		  $alt->{path}, $alt->{priority});
    foreach my $slave (@{ $alt->{slaves} }) {
	push @params, "--slave", $slave->{"link"}, $slave->{"name"}, $slave->{"path"};
    }
    call_ua(\@params, %opts);
}

sub remove_choice {
    my ($id, %opts) = @_;
    my $alt = $choices[$id];
    my @params = ("--remove", $main_name, $alt->{path});
    call_ua(\@params, %opts);
}

sub set_choice {
    my ($id, %opts) = @_;
    my $alt = $choices[$id];
    my @params = ("--set", $main_name, $alt->{path});
    call_ua(\@params, %opts);
}

sub config_choice {
    my ($id, %opts) = @_;
    my ($input,	$output) = ("", "");
    if ($id >= 0) {
	my $alt = $choices[$id];
	$input = $alt->{path};
    } else {
	$input = "0";
    }
    $input .= "\n";
    $opts{from_string} = \$input;
    $opts{to_string} = \$output;
    my @params = ("--config", $main_name);
    call_ua(\@params, %opts);
    #print STDERR "Output of @params for choice $input $output\n";
}

sub get_slaves_status {
    my ($id) = @_;
    my %slaves;
    # None of the slaves are installed
    foreach my $alt (@choices) {
	for(my $i = 0; $i < @{$alt->{slaves}}; $i++) {
	    $slaves{$alt->{slaves}[$i]{name}} = $alt->{slaves}[$i];
	    $slaves{$alt->{slaves}[$i]{name}}{"installed"} = 0;
	}
    }
    # except those of the current alternative
    if (defined($id)) {
	my $alt = $choices[$id];
	for(my $i = 0; $i < @{$alt->{slaves}}; $i++) {
	    $slaves{$alt->{slaves}[$i]{name}} = $alt->{slaves}[$i];
	    $slaves{$alt->{slaves}[$i]{name}}{"installed"} = 1;
	}
    }
    return sort { $a->{name} cmp $b->{name} } values %slaves;
}

sub check_link {
    my ($link, $value, $msg) = @_;
    ok(-l $link, "$msg: $link disappeared.");
    is(readlink($link), $value, "$link doesn't point to $value.");
}
sub check_no_link {
    my ($link, $msg) = @_;
    lstat($link);
    ok(!-e _, "$msg: $link still exists.");
    ok(1, "fake test"); # Same number of tests as check_link
}

sub check_slaves {
    my ($id, $msg) = @_;
    foreach my $slave (get_slaves_status($id)) {
	if ($slave->{installed}) {
	    check_link("$altdir/$slave->{name}", $slave->{path}, $msg);
	    check_link($slave->{"link"}, "$altdir/$slave->{name}", $msg);
	} else {
	    check_no_link("$altdir/$slave->{name}", $msg);
	    check_no_link($slave->{"link"}, $msg);
	}
    }
}
# (4 * (nb_slaves+1) + 2) tests in each check_choice() call
sub check_choice {
    my ($id, $mode, $msg) = @_;
    my $output;
    if (defined $id) {
	# Check status
	call_ua([ "--query", "$main_name" ], to_string => \$output);
	$output =~ /^Status: (.*)$/im;
	is($1, $mode, "$msg: status is not $mode.");
	# Check links
	my $alt = $choices[$id];
	check_link("$altdir/$main_name", $alt->{path}, $msg);
	check_link($main_link, "$altdir/$main_name", $msg);
	check_slaves($id, $msg);
    } else {
	call_ua([ "--query", "$main_name" ], to_string => \$output, expect_failure => 1);
	ok($output =~ /No alternatives/, "$msg: bad error message for --query.");
	# Check that all links have disappeared
	check_no_link("$altdir/$main_name", $msg);
	check_no_link($main_link, $msg);
	check_slaves(undef, $msg);
    }
}

### START OF TESTS
cleanup();
# removal when not installed should not fail
remove_choice(0);
# successive install in auto mode
install_choice(1);
check_choice(1, "auto", "initial install 1");
install_choice(2); # 2 is lower prio, stays at 1
check_choice(1, "auto", "initial install 2");
install_choice(0); # 0 is higher priority
check_choice(0, "auto", "initial install 3");
# manual change with set
set_choice(2);
check_choice(2, "manual", "manual update with --set"); # test #388313
remove_choice(2);
check_choice(0, "auto", "remove manual, back to auto");
remove_choice(0);
check_choice(1, "auto", "remove best");
remove_choice(1);
check_choice(undef, "", "no alternative left");
# single choice in manual mode, to be removed
install_choice(1);
set_choice(1);
check_choice(1, "manual", "single manual choice");
remove_choice(1);
check_choice(undef, "", "removal single manual");
# check auto-recovery of user mistakes (#100135)
install_choice(1);
ok(unlink("$bindir/generic-test"), "failed removal");
ok(unlink("$bindir/slave1"), "failed removal");
install_choice(1);
check_choice(1, "auto", "recreate links in auto mode");
set_choice(1);
ok(unlink("$bindir/generic-test"), "failed removal");
ok(unlink("$bindir/slave1"), "failed removal");
install_choice(1);
check_choice(1, "manual", "recreate links in manual mode");
# check recovery of /etc/alternatives/*
install_choice(0);
ok(unlink("$altdir/generic-test"), "failed removal");
install_choice(1);
check_choice(0, "auto", "<altdir>/generic-test lost, back to auto");
# test --config
config_choice(0);
check_choice(0, "manual", "config to best but manual");
config_choice(1);
check_choice(1, "manual", "config to manual");
config_choice(-1);
check_choice(0, "auto", "config auto");

# test rename of links
install_choice(0);
my $old_slave = $choices[0]{"slaves"}[0]{"link"};
my $old_link = $main_link;
$choices[0]{"slaves"}[0]{"link"} = "$bindir/more/generic-slave";
$main_link = "$bindir/more/mytest";
install_choice(0);
check_choice(0, "auto", "test rename of links");
check_no_link($old_link, "test rename of links");
check_no_link($old_slave, "test rename of links");
# rename with installing other alternatives
$old_link = $main_link;
$main_link = "$bindir/generic-test";
install_choice(1);
check_choice(0, "auto", "rename link");
check_no_link($old_link, "rename link");
# rename with lost file
unlink($old_slave);
$old_slave = $choices[0]{"slaves"}[0]{"link"};
$choices[0]{"slaves"}[0]{"link"} = "$bindir/generic-slave-bis";
install_choice(0);
check_choice(0, "auto", "rename lost file");
check_no_link($old_slave, "rename lost file");
# test install with empty admin file (#457863)
cleanup();
system("touch $admindir/generic-test");
install_choice(0);
# test install with garbage admin file
cleanup();
system("echo garbage > $admindir/generic-test");
install_choice(0, error_to_file => "/dev/null", expect_failure => 1);

# test invalid usages
cleanup();
install_choice(0);
# try to install a slave alternative as new master
call_ua(["--install", "$bindir/testmaster", "slave1", "/bin/date", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# try to install a master alternative as slave
call_ua(["--install", "$bindir/testmaster", "testmaster", "/bin/date", "10",
	 "--slave", "$bindir/testslave", "generic-test", "/bin/true" ],
	expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# try to reuse links in master alternative
call_ua(["--install", "$bindir/slave1", "testmaster", "/bin/date", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# try to reuse links in slave alternative
call_ua(["--install", "$bindir/testmaster", "testmaster", "/bin/date", "10",
	 "--slave", "$bindir/generic-test", "testslave", "/bin/true" ],
	expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# lack of absolute filenames in links or file path, non-existing path,
call_ua(["--install", "../testmaster", "testmaster", "/bin/date", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
call_ua(["--install", "$bindir/testmaster", "testmaster", "./update-alternatives.pl", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# non-existing alternative path
call_ua(["--install", "$bindir/testmaster", "testmaster", "$bindir/doesntexist", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# invalid alternative name in master
call_ua(["--install", "$bindir/testmaster", "test/master", "/bin/date", "10"],
        expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");
# invalid alternative name in slave
call_ua(["--install", "$bindir/testmaster", "testmaster", "/bin/date", "10",
	 "--slave", "$bindir/testslave", "test slave", "/bin/true" ],
	expect_failure => 1, to_file => "/dev/null", error_to_file => "/dev/null");

# TODO: install in non-existing dir, handle of pre-existing files in place
# of alternative links
