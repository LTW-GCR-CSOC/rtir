#!/usr/bin/perl

use strict;
use warnings;

use RT::IR::Test tests => undef;

my $ok = 1;

use File::Find;
find( {
    no_chdir => 1,
    wanted   => sub {
        return if /\.(?:jpe?g|png|gif)$/i;
        return if m{/\.[^/]+\.swp$}; # vim swap files
	return if /\.svn/i;
        return unless -f $_;
        diag "testing $_" if $ENV{'TEST_VERBOSE'};
        eval { compile_file($_) } and return;
        $ok = 0;
        diag "error in ${File::Find::name}:\n$@";
    },
}, 'html');
ok($ok, "mason syntax is ok");

use HTML::Mason;
use HTML::Mason::Compiler;
use HTML::Mason::Compiler::ToObject;

sub compile_file {
    my $file = shift;

    open my $fh, '<:utf8', $file or die "couldn't open '$file': $!";
    my $text = do { local $/; <$fh> };
    close $fh or die "couldn't close '$file': $!";

    my $compiler = HTML::Mason::Compiler::ToObject->new;
    $compiler->compile(
        comp_source => $text,
        name => 'my',
        $HTML::Mason::VERSION >= 1.36? (comp_path => 'my'): (),
    );
    return 1;
}
done_testing;
