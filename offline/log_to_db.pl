#!usr/bin/perl

# Скрипт, загружающий лог в БД. Синтаксис: log_to_db.pl [параметры]
# 	Параметры:
# 	[-l <log_file>] - использовать указанный файл. По умолчанию 'out'
# 	[-p <portion_size>] - количество записей, за раз вставляемых в БД. По умолчанию 20_000
# 	[-f] - Принудительное приведение значений NOT NULL столбцов (кроме created и int_id) от undef к пустым строкам (при построчной вставке)

# По-хорошему требуется уточнение условий.

# С одной стороны условия задачи, похоже, наточены на то, чтобы скрипт вставлял записи по одной. При этом БД не позволит вставить undef в NOT NULL столбцы.
# С другой стороны, это будет медленно и на приличных объемах лучше вставлять пачкой. Однако тогда эти значения будут приведены к ''/0 и вставятся.

# И какое именно поведение требуется - вставить/не вставить - я не знаю.

# Вышел из положения тем, что по умолчанию идет вставка пачками (которая в случае ошибки переходит в построчный режим), но перед вставкой каждая запись самим скриптом
# проверяется на undef по этим полям (required_fields) (кроме created и int_id, если они пустые, отвалится по ошибке на этапе разбора строки лога).
# Такой себе костыль, но взаимодействие с БД обычно бутылочное горлышко, надо его уважать.

# Можно изменить поведение это скрипта параметром -f

# С обработкой адресов возможно сделал что-то не так как задумано, но по логу не всё очевидно, нужны ли например только емайлы (или то, что перед ними - тоже).

use strict;
use DBI;

my $dbi;

connect_db ();

my %_ARGV = get_args ();

my $file_name = $_ARGV {l} || 'out';
my $portion = $_ARGV {p} || 20_000;
my $is_force_insert = exists $_ARGV {f};

print "Log file: $file_name; portion: $portion; force insert: " . ($is_force_insert ? 'yes' : 'no') . ".\n";
open my $log_file, '<', $file_name or die "Can't open log file.\n";

my $data_to_insert;
my ($cnt, $cnt_match, $cnt_not_match, $cnt_to_db, $cnt_db_bulk_errors, $cnt_db_bulk_inserted, $cnt_db_row_errors, $cnt_db_rows_inserted) = (0) x 8;

my $fields = {
	message                 => [qw /created id int_id str/],
	message_required_fields => [qw /id str/], # для дополнительной проверки на NOT NULL при вставке пачкой (см комментарий выше)
	log                     => [qw /created int_id str address/],
	log_required_fields     => [],            # для log не нужно, до этого не дойдет
};

while (<$log_file>) {
	chomp;
	$cnt++;
	my $is_matched =
		/^
			(?<created>\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}) # дата, время
			\s
			(?<str> # строка без временной метки
				(?<int_id>[^\s]+) # id
				\s
				(
					(?<flag><=|=>|->|\*\*}|==)
					\s
					(?<address><>|.+?@[^\s]+)
					\s
				)? # возможно, есть флаг, тогда возьмем и адрес (который вопреки условию задачи "пробел=разделитель", кстати, может содержать пробелы)
				( # другая информация, в которой может быть id
					.*?
					id=(?<id>.+)
					|
					.*
				)
			)
		$/x;

	if ($is_matched) {
		$cnt_match++;

		my $destination = $+ {flag} eq '<=' ? 'message' : 'log';

		my @error_fields = grep {!defined $+ {$_}} @{$fields -> {$destination . '_required_fields'}};

		if (@error_fields && !$is_force_insert) {
			print "-- Not defined required field(s) in row #$cnt: " . (join ', ', @error_fields) . "\n";
		} else {
			my %field_value = %+;

			$field_value {$_} ||= '' foreach (@error_fields);

			push @{$data_to_insert -> {$destination}}, {
				(map {$_ => $field_value {$_}} @{$fields -> {$destination}}),
				cnt => $cnt,
			};
			$cnt_to_db++;
			insert_data ($destination) if (@{$data_to_insert -> {$destination}} >= $portion);
		}

	} else {
		$cnt_not_match++;
		print "-- Error: row #$cnt has wrong format\n";
	}
}

my $cnt_nulls = $cnt_match - $cnt_to_db;

insert_data ($_) foreach (qw/message log/);

print "\nTotal: " . ($cnt_match + $cnt_not_match) . " log rows passed, $cnt_match OK" . ($cnt_not_match ? ", incorrect format: $cnt_not_match rows" : '') . ".\n";
print "Sent to DB: $cnt_to_db from $cnt_match rows." . ($cnt_nulls ? " $cnt_nulls rows contain NULLs." : '') . "\n";
print "DB rows inserted by bulk: $cnt_db_bulk_inserted from " . ($cnt_db_bulk_inserted + $cnt_db_bulk_errors) . " rows, $cnt_db_bulk_errors errors.\n";
print "DB single row insertions: $cnt_db_rows_inserted rows OK, $cnt_db_row_errors errors.\n";

###############################################################

sub connect_db {
	my $dsn = "DBI:mysql:gazprombank_test";
	my $user = "root";
	my $password = "";
	$dbi = DBI -> connect ($dsn, $user, $password, {RaiseError => 1, PrintError => 0}) or die "\nERROR: Can't connect, stopped.\n";
}

###############################################################

sub get_args {
	my $arg_name;
	my %args;
	foreach (@ARGV) {
		if (/-(\w+)/) {
			$arg_name = $1;
			$args {$arg_name} = undef;
		} elsif ($arg_name) {
			$args {$arg_name} = $_;
			undef $arg_name;
		}
	}
	return %args;
}

################################################################################

sub sql_select_all {

	my ($sql, @params) = @_;

	$sql =~ s{^\s+}{};

	my $st = $dbi -> prepare ($sql);
	$st -> execute (@params);

	my $result = $st -> fetchall_arrayref ({});
	$st -> finish;

	return $result;

}

################################################################################

sub sql_do {

	my ($sql, @params) = @_;

	my $st = $dbi -> prepare ($sql);
	my $result;
	$result = $st -> execute (@params);

	$st -> finish;

}

################################################################################

sub insert_data {

	my $destination = shift;

	return unless (defined $data_to_insert -> {$destination} && @{$data_to_insert -> {$destination}});

	print "Trying to insert " . @{$data_to_insert -> {$destination}} . " rows to table '$destination'...\n";

	my $row_placeholders = '(' . (join ',', ('?') x @{$fields -> {$destination}}) . ')';

	my @params;
	my $cnt_bulk_to_insert;
	my $cnt_bulk_errors;
	my $rows_to_insert;

	foreach my $row (@{$data_to_insert -> {$destination}}) {
		my @error_fields = grep {!defined $row -> {$_}} @{$fields -> {$destination . '_required_fields'}};
		if (@error_fields) {
			print "-- Not defined field(s) in row #$row->{cnt}: " . (join ', ', @error_fields) . "\n";
			$cnt_bulk_errors++;
		} else {
			push @$rows_to_insert, $row;
			$cnt_bulk_to_insert++;
		}
	}

	if ($cnt_bulk_to_insert) {
		my $sql_prefix = "INSERT INTO $destination (" . (join ',', @{$fields -> {$destination}}) . ") VALUES ";
		my $sql =  $sql_prefix . (join ',', ($row_placeholders) x (@$rows_to_insert));

		foreach my $row (@$rows_to_insert) {
			push @params, map {$row -> {$_}} @{$fields -> {$destination}};

		}
		eval {
			sql_do ($sql, @params);
		};

		if ($@) { # При вставке пачки что-то пошло не так, переходим в режим вставки по одной строке
			$@ =~ s/^(.+execute failed: )//;
			print "-- Error: $@    ... switching to single rows mode...\n";

			$dbi -> ping () or connect_db (); # Поднять соединение, если упало (например, при превышении max_allowed_packet)

			$sql =  $sql_prefix . $row_placeholders;

			foreach my $row (@$rows_to_insert) {
				@params = map {$row -> {$_}} @{$fields -> {$destination}};

				eval {
					sql_do ($sql, @params);

				};
				if ($@) {
					$@ =~ s/^(.+execute failed: )//;
					print "-- Error inserting row #$row->{cnt}: $@";
					$cnt_db_row_errors++;
				} else {
					$cnt_db_rows_inserted++;
				}
			}
			$cnt_db_bulk_errors += $cnt_bulk_to_insert;
		} else {
			print "    ... ok.\n";
			$cnt_db_bulk_inserted += $cnt_bulk_to_insert;
		}
	}

	$cnt_db_bulk_errors += $cnt_bulk_errors;

	undef $data_to_insert -> {$destination};

}