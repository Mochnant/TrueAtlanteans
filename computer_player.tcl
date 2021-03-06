lappend ::auto_path [pwd]
package require client_utils

namespace eval atl_cp {
	set terrain_priority {
		plain 0
		mountain 1
		forest 2
		mystforest 2
		jungle 3
		swamp 3
		lake 3
		hill 4
		desert 5
		wasteland 6
		tundra 7
	}
}

namespace eval gui {
	set currentTurn 0
}

proc evaluateSituation {} {
	set ret [dict create]

	set units [db eval {
		SELECT detail.x, detail.y, detail.z, units.id, units.name, units.uid, units.items, units.orders
		FROM detail JOIN units
		ON detail.id=units.regionId
		WHERE detail.turn=$gui::currentTurn and units.detail='own'
	}]
	dict set ret Units $units

	if {$units eq ""} {
		dict set ret "State" "lost"
	} elseif {[llength $units] == 8} {
		dict set ret "State" "start"
	} else {
		dict set ret "State" "main"
	}

	return $ret
}

proc buyGuards {budget claim x y z} {
	set rdata [db eval {
		SELECT id, sells, race, tax
		FROM detail
		WHERE x=$x AND y=$y AND z=$z AND turn=$gui::currentTurn
		ORDER BY turn DESC LIMIT 1
	}]
	if {$rdata eq ""} {
		puts "Unable to retrieve region data"
		exit 1
	}
	foreach {regionId sells peasants maxTax} $rdata {}

	set taxersNeeded [expr {$maxTax / 50}]
	if {$taxersNeeded == 0} {
		puts "No tax in region!"
		exit -1
	}

	set ret [getBuyRace $sells $peasants]
	foreach {maxRace raceList price} $ret {}

	# limit by cash on hand
	# TODO configure maintenance cost
	set maxBuy [expr {$budget / ($price + 20)}]
	set numBuy [expr {min($taxersNeeded, $maxBuy, $maxRace)}]
	if {$numBuy == 0} {
		return [list "" ""]
	}

	regexp {\[(.+)\]} [lindex $raceList 0] -> abbr

	lappend ol "form 1" "name unit Guard"

	if {$claim} {
		set claimAmt [expr {$numBuy * ($price + 10)}]
		lappend ol "claim $claimAmt"
	}

	lappend ol "avoid 0" "behind 0"
	lappend ol "buy $numBuy $abbr"
	lappend ol "study COMB"
	lappend ol "turn" "@tax" "endturn"
	lappend ol "end"

	return [list [expr {$numBuy * ($price + 10)}] $ol]
}

proc rampFirstHex {units} {
	foreach {x y z unit_id name uid il ol} $units {}

	# TODO check to make sure we got out of the starting city (exit wasn't blocked)
	# TODO calculate a good budget to use
	set budget 3000

	set ret [buyGuards $budget 1 $x $y $z]
	foreach {price form_orders} $ret {}

	set ol [concat $ol $form_orders]
	lappend ol "claim 100"
	lappend ol "study FORC"

	db eval {
		UPDATE units SET orders=$ol
		WHERE id=$unit_id
	}
}

proc pickStartDirection {units} {
	set exits [list]

	set res [db eval {
		SELECT dir, dest
		FROM nexus_exits
	}]
	foreach {dir dest} $res {
		set ex_n [dict create]
		dict set ex_n Dir $dir
		dict set ex_n Loc $dest

		foreach {x y z} $dest {}
		set terrain [db eval {
			SELECT type FROM terrain
			WHERE x=$x and y=$y and z=$z
		}]
		dict set ex_n Terrain $terrain
		dict set ex_n Score [dict get $atl_cp::terrain_priority $terrain]

		lappend exits $ex_n
	}

	# find the best
	set sorted_exits [lsort -index 7 $exits]
	set e [lindex $sorted_exits 0]
	set best_score [dict get $e Score]
	set best_dir [dict get $e Dir]
	foreach e [lrange $sorted_exits 1 end] {
		if {$best_score < [dict get $e Score]} {
			break
		}
		# TODO selection criteria
	}

	set best_loc [dict get $res $best_dir]
	foreach {x y z} $best_loc {}
	if {$y > 15} {
		set dir2 nw
	} else {
		set dir2 se
	}

	foreach {x y z unit_id name uid il ol} $units {
		lappend ol "behind 1" "avoid 1"
		lappend ol [format {move %s %s} $best_dir $dir2]
		db eval {
			UPDATE units SET orders=$ol
			WHERE id=$unit_id
		}
	}
}

# have leader do something
proc advanceLeader {u} {
	if {$u eq ""} return

	set ol [$u cget -orders]
	set il [$u cget -items]
	set sl [$u cget -skills]

	set silver [$u countItem SILV]

	# fire first
	set i [lsearch $sl *FIRE*]
	if {$i == -1} {
		# requires force
		set i [lsearch $sl *FORC*]
		if {$i == -1} {
			if {$silver < 100} {
				lappend ol "claim [expr {100 - $silver}]"
			}
			lappend ol "STUDY FORC"
		} else {
			if {$silver < 100} {
				lappend ol "claim [expr {100 - $silver}]"
			}
			lappend ol "STUDY FIRE"
			lappend ol "turn" "combat fire" "endturn"
		}
	} else {
		# got fire, go for tact
		if {$silver < 200} {
			lappend ol "claim [expr {200 - $silver}]"
		}
		lappend ol "STUDY TACT"
	}

	$u configure -orders $ol
}

proc processRegion {rid} {
	set units [getUnitObjects $rid]

	# pull region info
	set res [::db eval {
		SELECT x,y,z, wages, tax, entertainment, wants, sells, products, exitDirs
		FROM detail
		WHERE id=$rid
	}]
	foreach {x y z wages tax ente wants sells products exits} $res {}

	# get all the funds here
	set totalSilver 0
	set leader ""
	set funds [list]
	foreach u $units {
		set silver [$u countItem SILV]
		if {$silver != 0} {
			incr totalSilver $silver
			lappend funds $u $silver
		}

		set items [$u cget -items]
		set ol [$u cget -orders]
		set sl [$u cget -skills]
		if {[regexp {PATT} $sl] != 0} {
			# leader
			set leader $u
		} elseif {[ordersMatch $ol "tax"] != -1} {
		} elseif {[regexp {COMB} $sl] != 0} {
		}
	}

	# fund leader training
	if {$leader ne ""} {
		set s_need 200
		if {$totalSilver >= $s_need} {
			for {set i 0} {$s_need > 0 && $i < [llength $funds]} {incr i 2} {
				set u [lindex $funds $i]
				set s [lindex $funds $i+1]

				if {$s >= $s_need} {
					# goal achieved
					set s_give $s_need
					set s_left [expr {$s - $s_need}]
				} elseif {$s > 0} {
					set s_need [expr {$s_need - $s}]
					set s_give $s
					set s_left 0
				}

				# create the give order
				if {$s_give > 0} {
					set order_text "GIVE [$leader cget -num] $s_give SILV"

					set give_o [$u cget -orders]
					lappend give_o $order_text
					$u configure -orders $give_o

					# update giving unit
					$u setItem SILV $s_left
					set funds [lreplace $funds $i+1 $i+1 $s_left]
					incr totalSilver -$s_give

					# update leader
					set leader_funds [$leader countItem SILV]
					$leader setItem SILV [expr {$leader_funds + $s_give}]
				}
			}
		}

		advanceLeader $leader
	}

	# buy tax men
	set ret [buyGuards $totalSilver 0 $x $y $z]
	foreach {s_need form_orders} $ret {}

	if {$s_need > 0} {
		for {set i 0} {$s_need > 0 && $i < [llength $funds]} {incr i 2} {
			set u [lindex $funds $i]
			set s [lindex $funds $i+1]

			if {$s >= $s_need} {
				# goal achieved
				set s_give $s_need
				set s_left [expr {$s - $s_need}]
			} elseif {$s > 0} {
				set s_need [expr {$s_need - $s}]
				set s_give $s
				set s_left 0
			}

			# create the give order
			if {$s_give > 0} {
				set order_text "GIVE NEW 1 $s_give SILV"

				set give_o [$u cget -orders]
				lappend give_o $order_text
				$u configure -orders $give_o

				# update giving unit
				$u setItem SILV $s_left
				set funds [lreplace $funds $i+1 $i+1 $s_left]
				incr totalSilver -$s_give
			}
		}

		# have first unit do the form
		set form_unit [lindex $units 0]
		set ol [$form_unit cget -orders]
		lappend ol {*}$form_orders
		$form_unit configure -orders $ol
	}

	# save out orders
	foreach u $units {
		set ol [$u cget -orders]
		set unit_id [$u cget -db_id]

		db eval {
			UPDATE units SET orders=$ol
			WHERE id=$unit_id
		}
	}
}

proc createOrders {sitRep} {
	set units [dGet $sitRep Units]
	if {[dict get $sitRep State] == "start"} {
		# only one unit
		set zlevel [lindex $units 2]
		if {$zlevel == 0} {
			# we're in the nexus
			# choose an exit
			pickStartDirection $units
			return
		}
		#else, exited nexus
		rampFirstHex $units
		return
	}
	#else post-start
	# process per region
	set res [::db eval {
		SELECT detail.x, detail.y, detail.z, detail.id
		FROM detail JOIN units
		ON detail.id=units.regionId
		WHERE detail.turn=$gui::currentTurn AND units.detail='own'
		ORDER BY detail.z, detail.x, detail.y
	}]

	set loc ""
	set old_rid 0
	foreach {x y z rid} $res {
		set newLoc [list $x $y $z]
		if {$loc eq ""} {
			set loc $newLoc
			set old_rid $rid
		} elseif {$loc ne $newLoc} {

			# location change - process current list with old rid
			processRegion $old_rid

			set loc $newLoc
			set old_rid $rid
		}
	}

	processRegion $old_rid
}

proc saveOrders {} {
	set filename [format {orders.%d} [expr {$gui::currentTurn + 1}]]

	set f [open $filename "w"]

	set pid [::db onecolumn { SELECT player_id FROM settings }]
	set ppass [::db onecolumn { SELECT player_pass FROM settings }]
	if {$ppass eq ""} {
		puts $f "#atlantis $pid"
	} else {
		puts $f "#atlantis $pid \"$ppass\""
	}

	set res [::db eval {
		SELECT units.name, units.uid, units.orders, detail.x, detail.y, detail.z
		FROM detail JOIN units
		ON detail.id=units.regionId
		WHERE detail.turn=$gui::currentTurn AND units.detail='own'
		ORDER BY detail.z, detail.x, detail.y
	}]

	set loc ""
	foreach {u uid ol x y z} $res {
		if {$ol eq ""} continue

		set newLoc [list $x $y $z]
		if {$loc eq "" || $loc ne $newLoc} {
			set loc $newLoc
			puts $f ";*** $x $y $z ***"
		}

		puts $f "unit $uid"
		puts $f "; $u"
		puts $f "[join $ol "\n"]\n"
	}

	puts $f "#end"
	close $f
}

# main
if {![info exists debug]} {
	if {$argc < 2} {
		puts "Usage $argv0 <command> <dir>"
		puts "Commands: "
		foreach c {new add gen} {
			puts "\t$c"
		}
	}

	set cmd [lindex $argv 0]
	cd [lindex $argv 1]

	if {$cmd eq "new"} {
		createDb "game.db"
		exit 0
	}

	#else open game db
	set errMsg [openDb "game.db"]
	if {$errMsg ne ""} {
		puts $errMsg
		exit 1
	}

	if {$cmd eq "add"} {
		loadData [lindex $argv 2]
		exit 0
	}

	if {$cmd ne "gen"} {
		puts "Unkwown command '$cmd"
		exit 1
	}

	# generate orders for current turn
	set ::men [db eval {select abbr from items where type="race"}]
	set gui::currentTurn [db eval {select max(turn) from detail}]

	set sitRep [evaluateSituation]
	createOrders $sitRep
	saveOrders
}

