package require atlantis_utils
package require sqlite3
package provide atlantis_dbtools 1.0

# (database available function)
# return amount of tax revenue in hex given by 'rid'
# (capped by maxTax extracted from detail table)
proc curTax {rid maxTax} {
	# ocean hexes have null maxTax
	if {$maxTax eq ""} { return 0 }

	# pull all the units in the region
	set res [::db eval {
		SELECT items,orders
		FROM units
		WHERE regionId=$rid
	}]

	# count number of men taxing
	set taxers 0
	foreach {il ol} $res {
		if {[ordersMatch $ol "tax"] != -1} {
			incr taxers [countMen $il]
		}
	}

	# can't tax more than maxTax
	return [expr min($taxers*50, $maxTax)]
}

# return a list of producers in hex given by 'rid'
# (capped by the maximums in maxProducts)
proc curProduce {rid maxProducts} {
	# pull all the units in the region
	set res [::db eval {
		SELECT items,orders,skills
		FROM units
		WHERE regionId=$rid
	}]

	set maxProdDict [buildProductDict $maxProducts]
	set ret ""
	# foreach result
	foreach {il ol sl} $res {
		set idx [ordersMatch $ol "produce"]
		if {$idx != -1} {
			set o [lindex $ol $idx]
			set product [string toupper [lindex $o 1]]
			if {![dict exists $::production $product]} {
				puts "No product $product"
			}
			set numMen [countMen $il]
			dict set ret $product $numMen
		}
	}

	return $maxProdDict
}

proc countItem {ils item} {
	foreach il $ils {
		if {[lindex $il 2] eq [format {[%s]} $item]} {
			return [lindex $il 0]
		}
	}

	return 0
}

proc registerFunctions {} {
	::db function curTax curTax
	::db function curProduce curProduce
	::db function countItem countItem
	::db function countMen countMen
}

proc createDb {filename} {
	if {[info exists ::db]} {
		::db close
	}
	sqlite3 ::db $filename

	# settings
	::db eval {
		CREATE TABLE settings(
		id INTEGER PRIMARY KEY,
		version INTEGER,
		player_id INTEGER,
		player_pass TEXT not null,
		geom_top TEXT not null,
		zoom_level INTEGER,
		view_level INTEGER,
		forSale_open INTEGER
		);
	}

	::db eval {
		INSERT INTO settings
		(id, version, player_id, player_pass, geom_top, zoom_level, view_level, forSale_open)
		VALUES(1, 1, 0, "", "", 0, 0, 0)
	}

	# terrain table: (x, y, z) -> terrain type, city, region name
	::db eval {
		CREATE TABLE terrain(
		x TEXT not null,
		y TEXT not null,
		z TEXT not null,
		type not null,
		city not null,
		region not null,
		  unique(x,y,z));
	}

	# detailed table: (x, y, z) -> turn info gathered, wants?, sells?, weather(cur,
	# next) wage(per, max)
	::db eval {
		CREATE TABLE detail (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			x TEXT not null,
			y TEXT not null, 
			z TEXT not null,
			turn INTEGER not null,
			weather not null,
			wages not null,
			pop not null,
			race not null,
			tax not null,
			entertainment not null,
			wants not null,
			sells not null,
			products not null,
			exitDirs not null,
			  unique(x,y,z,turn)
		);
	}

	::db eval {
		CREATE TABLE nexus_exits (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			dir not null,
			dest not null,
				unique(dir)
		);
	}

	# unit table: (regionId) -> name, description, detail (own or foreign), orders
	::db eval {
		CREATE TABLE units (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			regionId INTEGER not null,
			name not null,
			uid INTEGER not null,
			desc not null,
			faction not null,
			detail not null,
			orders not null,
			items not null,
			skills not null,
			flags not null,
			FOREIGN KEY (regionId) REFERENCES detail(id)
			  ON DELETE CASCADE
			  ON UPDATE CASCADE
		);
	}

	# object table
	::db eval {
		CREATE TABLE objects (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			regionId INTEGER not null,
			name not null,
			desc not null,
			FOREIGN KEY (regionId) REFERENCES detail(id)
				ON DELETE CASCADE
				ON UPDATE CASCADE
		);
	}

	# object to unit mappings (what units are in which objects)
	::db eval {
		CREATE TABLE object_unit_map (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			objectId INTEGER not null,
			unitId INTEGER not null,
			FOREIGN KEY (objectId) REFERENCES objects(id)
				ON DELETE CASCADE
				ON UPDATE CASCADE,
			FOREIGN KEY (unitId) REFERENCES units(id)
				ON DELETE CASCADE
				ON UPDATE CASCADE
		);
	}

	# item descriptions (desc is a dict)
	::db eval {
		CREATE TABLE items(
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT not null,
			abbr TEXT not null unique on conflict replace,
			type TEXT not null,
			desc TEXT not null
		)
	}

	# skill descriptions (desc is a list)
	::db eval {
		CREATE TABLE skills(
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			name TEXT not null,
			abbr TEXT not null,
			level TEXT not null,
			cost TEXT not null,
			desc TEXT not null
		)
	}

	# active markers
	::db eval {
		CREATE TABLE active_markers(
			x TEXT not null,
			y TEXT not null,
			z TEXT not null,
			done not null,
			  unique(x,y,z)
		)
	}

	registerFunctions
}

proc openDb {ofile} {
	if {[info exists ::db]} {
		::db close
	}
	sqlite3 ::db $ofile
	set res [db eval {SELECT name from sqlite_master}]
	if {[lsearch $res terrain] == -1 ||
	    [lsearch $res detail]  == -1} {
		::db close
		unset ::db
		return "Error file $ofile is invalid"
	}

	registerFunctions
	return ""
}

proc insertItem {i} {
	set nd [dict get $i "Name"]
	regexp { *([^[]*)  *\[(.*)\]} $nd -> name abbr

	set type [dict get $i "Type"]

	set desc [dict remove $i "Name" "Type"]
	::db eval {
		INSERT INTO items
		(name, abbr, type, desc)
		VALUES($name, $abbr, $type, $desc)
	}
}

proc taxProgressDetailed {} {
	return [::db eval {
		SELECT x, y, z, turn, curTax(id, tax)
		FROM detail
		ORDER BY turn
	}]
}

proc taxProgress {} {
	return [::db eval {
		SELECT turn, sum(curTax(id, tax))
		FROM detail
		GROUP BY turn
	}]
}

proc getUnits {name} {
	return [::db eval {
		SELECT detail.x, detail.y, detail.z, units.name, units.uid
		FROM detail JOIN units
		ON detail.id=units.regionId
		WHERE detail.turn=$gui::currentTurn and units.detail='own' and units.name LIKE $name
	}]
}

# helper for updateDb
# process the exits field
# returns a list of all exit directions (for wall processing)
proc doExits {db exits rz} {
	set dirs ""

	#foreach direction and exit info
	foreach {d e} $exits {
		lappend dirs $d ;# save the exit direction

		# pull the terrain info from the exit info
		set loc [dGet $e Location]
		set x [lindex $loc 0]
		set y [lindex $loc 1]
		set z [lindex $loc 2]

		set ttype  [dGet $e Terrain]
		set city   [dGet $e Town]
		set region [dGet $e Region]

		$db eval {
			INSERT OR REPLACE INTO terrain VALUES
			($x, $y, $z, $ttype, $city, $region);
		}

		if {$rz == 0} {
			$db eval {
				INSERT OR REPLACE INTO nexus_exits (dir, dest)
				VALUES ($d, $loc);
			}
		}
	}

	return $dirs
}

proc dbInsertUnit {db regionId u} {
	set name   [dGet $u Name]
	set desc   [dGet $u Desc]
	set fact   [dGet $u Faction]
	set detail [dGet $u Report]
	set orders [dGet $u Orders]
	set items  [dGet $u Items]
	set skills [dGet $u Skills]
	set flags  [dGet $u Flags]

	set r [extractUnitNameNum $name]
	set n [lindex $r 0]
	set uid [lindex $r 1]

	$db eval {
		INSERT INTO units
		(regionId, name, uid, desc, faction, detail, orders, items, skills, flags)
		VALUES(
		$regionId, $n, $uid, $desc, $fact, $detail, $orders, $items, $skills, $flags
		);
	}
	return [$db last_insert_rowid]
}

proc insertSkill {s} {
	set name [dGet $s "Name"]
	set abbr [dGet $s "Abbr"]
	set level [dGet $s "Level"]
	set cost [dGet $s "Cost"]
	set desc [dGet $s "Desc"]

	::db eval {
		INSERT INTO skills
		(name, abbr, level, cost, desc)
		VALUES($name, $abbr, $level, $cost, $desc)
	}
}

proc updateDb {db tdata} {
	set pid [dGet $tdata PlayerNum]
	set ppass [dGet $tdata PlayerPass]
	db eval {
		UPDATE settings SET
		player_id = $pid,
		player_pass = $ppass
	}
	set turnNo [calcTurnNo [dGet $tdata Month] [dGet $tdata Year]]

	$db eval {BEGIN TRANSACTION}

	set regions [dGet $tdata Regions]
	foreach r $regions {

		set loc [dGet $r Location]
		set x [lindex $loc 0]
		set y [lindex $loc 1]
		set z [lindex $loc 2]

		set dirs [doExits $db [dGet $r Exits] $z]

		set ttype [dGet $r Terrain]

		set city    [dGet $r Town]
		set region  [dGet $r Region]

		$db eval {
			INSERT OR REPLACE INTO terrain VALUES
			($x, $y, $z, $ttype, $city, $region);
		}

		set weather [list [dGet $r WeatherOld] [dGet $r WeatherNew]]
		set wages   [list [dGet $r Wage] [dGet $r MaxWage]]
		set pop     [dGet $r Population]
		set race    [dGet $r Race]
		set tax     [dGet $r MaxTax]
		set ente    [dGet $r Entertainment]
		set wants   [dGet $r Wants]
		set sells   [dGet $r Sells]
		set prod    [dGet $r Products]
		$db eval {
			INSERT OR REPLACE INTO detail
			(x, y, z, turn, weather, wages, pop, race, tax, entertainment, wants,
			 sells, products, exitDirs)

			VALUES(
			$x, $y, $z, $turnNo, $weather, $wages, $pop, $race, $tax, $ente,
			$wants, $sells, $prod, $dirs
			);
		}

		set regionId [$db last_insert_rowid]
		set units [dGet $r Units]
		foreach u $units {
			dbInsertUnit $db $regionId $u
		}

		set objects [dGet $r Objects]
		foreach o $objects {
			set oname [dGet $o Name]
			set odesc [dGet $o ObjectName]
			$db eval {
				INSERT OR REPLACE INTO objects
				(regionId, name, desc)
				VALUES(
				$regionId, $oname, $odesc
				)
			}
			set objectId [$db last_insert_rowid]

			foreach u [dGet $o Units] {
				set unitRow [dbInsertUnit $db $regionId $u]
				$db eval {
					INSERT OR REPLACE INTO object_unit_map
					(objectId, unitId)
					VALUES($objectId, $unitRow)
				}
			}
		}
	}

	# items are a list of dict
	set items [dGet $tdata Items]
	foreach item $items {
		insertItem $item
	}

	set skills [dGet $tdata Skills]
	foreach skill $skills {
		insertSkill $skill
	}

	$db eval {END TRANSACTION}
}

