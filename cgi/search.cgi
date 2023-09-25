#!/usr/bin/perl

use lib 'c:/xampp2/perl/vendor/lib';

use strict;
use DBI;
use JSON;

my $dbi;

connect_db ();

my %query = map {my ($param, $value) = split("=", $_); $param, urldecode($value)} split('&',$ENV{'QUERY_STRING'});

my @fields = grep {$query {$_}} qw /address int_id id str/;
my $is_exact = $query {exact};
my $search_string = $query {'search'};
$search_string = "%" . $search_string . "%" unless $is_exact;

print "Content-Type: text/html\r\n\r\n";

unless (@fields && $search_string){
	print (encode_json {error => 1});

	exit;
}

my $db_searchable_fields = {
	message => {map {$_ => 1} qw /id int_id str/},
	log     => {map {$_ => 1} qw /int_id str address/},
};
my $sql_cols = {
	message => <<SQL,
		created
		, id
		, int_id
		, str
		, status
		, NULL as address
SQL
	log => <<SQL,
		created
		, NULL AS id
		, int_id
		, str
		, NULL AS status
		, address
SQL
};

my $filters;
my @params;
my @sql_parts;

foreach my $table (qw/message log/) {

	my @filters;
	foreach (grep {$db_searchable_fields -> {$table} {$_}} @fields) {

		push @filters, ($is_exact ? "$_ = ?" : "$_ LIKE ?");
		push @params, $search_string;
	}
	if (@filters) {
		push @sql_parts, $sql_cols -> {$table} . " FROM $table WHERE " . (join ' OR ', @filters);

	}

}

my $sql = 'SELECT SQL_CALC_FOUND_ROWS ' . (join ' UNION ALL SELECT ', @sql_parts) . ' ORDER BY int_id, created LIMIT 100';

my $result = sql_select_all ($sql, @params);

my $rows_cnt = sql_select_scalar ("SELECT found_rows()");

my $output = {
	result => $result,
	total_rows => $rows_cnt,
	rows => scalar(@$result),
};

my $json_text = encode_json $output;
print $json_text;

###############################################################

sub urldecode {
	my $val= shift ;
	$val=~s/\+/ /g;
	$val=~s/%([0-9A-H]{2})/pack('C',hex($1))/ge;
	return $val;
}

###############################################################

sub connect_db {
	my $dsn = "DBI:mysql:gazprombank_test";
	my $user = "root";
	my $password = "";
	$dbi = DBI -> connect ($dsn, $user, $password, {RaiseError => 1, PrintError => 0}) or die "\nERROR: Can't connect, stopped.\n";
}

################################################################################

sub sql_select_all {

	my ($sql, @params) = @_;

	my $st = $dbi -> prepare ($sql);
	$st -> execute (@params);

	my $result = $st -> fetchall_arrayref ({});
	$st -> finish;

	return $result;
}

################################################################################

sub sql_select_scalar {

	my ($sql, @params) = @_;

	my @result;

	my $st = $dbi -> prepare ($sql);
	$st -> execute (@params);

	@result = $st -> fetchrow_array ();

	$st -> finish;

	return $result [0];
}
