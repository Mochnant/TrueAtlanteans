set ::nextLine ""

proc getSection {f} {
	set ret $::nextLine

	set i1 [regexp -inline -indices {^[ \t]*[^ \t]} $::nextLine]
	set i1 [lindex $i1 0]
	set l [string trimright [gets $f]]

	while {![eof $f]} {
		if {$::nextLine eq ""} {
			append ret $l
			set ::nextLine $l
			set i1 [regexp -inline -indices {^[ \t]*[^ \t]} $::nextLine]
			set i1 [lindex $i1 0]
			set l [gets $f]
			continue
		}

		set i2 [regexp -inline -indices {^[ \t]*[^ \t]} $l]
		set i2 [lindex $i2 0]
		if {$l eq "" || [lindex $i1 1] == [lindex $i2 1]} {
			set ::nextLine $l
			return $ret
		}
		append ret $l

		set l [gets $f]
	}

	return $ret
}

proc searchListOfDict {l i key val} {
	set d [lindex $l $i]
	set v [dict get $d $key]

	return [expr {$v eq $val}]
}

# try and pull a unit's orders (unit is in region xy)
proc doRegionOrders {f regionVar xy} {
	set v [getSection $f]
	if {[eof $f]} { return "" }

	if {[lindex $v 0] ne "unit"} {
		set loc [lindex $v 2]
		set xy [string map {( "" ) "" , " "} $loc]
		return $xy
	}

	# save name
	set nameLine $::nextLine
	set ::nextLine ""

	# pull the orders
	set orders ""
	set v [gets $f]
	while {$v ne ""} {
		# skip comments
		if {[string index $v 0] ne ";"} {
			lappend orders $v
		}

		set v [gets $f]
	}

	if {$orders eq ""} {
		# no orders for this unit
		return $xy
	}

	upvar $regionVar regions

	set i 0
	while {![searchListOfDict $regions $i "Location" $xy]} {
		incr i
	}
	set r [lindex $regions $i]

	# try and get name
	regexp {^;(.* \([[:digit:]]+\)), } $nameLine -> unitName

	set units [dict get $r Units]
	set j 0
	while {![searchListOfDict $units $j "Name" $unitName]} {
		incr j
	}

	# put the orders into the unit list
	set u [lindex $units $j]
	dict set u "Orders" $orders
	set units [lreplace $units $j $j $u]

	# update region
	dict set r Units $units
	set regions [lreplace $regions $i $i $r]

	return $xy
}

proc parseRegion {v} {
	# crack the region definition into chunks
	# terrain (one word) location (x,y[,z] <underworld>?) in Region contains...
	set r [regexp {([^() ]+) (\([[:digit:],]+[^)]*\)) in (.*)} $v -> \
	  terrain loc rest]
	if {$r != 1} {
		puts "Unable to parse region '$v'"
		exit
	}

	# Terrain
	set ret [dict create Terrain $terrain]

	# Location
	regexp {\(([[:digit:]]+),([[:digit:]]+),?([[:digit:]]+)?} \
	   $loc -> x y z

	set l [list $x $y]
	if {$z ne ""} {lappend l $z}
	dict set ret Location $l

	set rest [string map {"\n" " "} [string trimright $rest "."]]
	set lm [split $rest ","]

	# Region
	dict set ret Region [lindex $lm 0]

	# Check for town
	set i 1
	set lmi [lindex $lm $i]
	set town ""
	if {[lindex $lmi 0] eq "contains"} {
		incr i ;# pull peasants from next i

		set town [lindex $lmi 1]

		set j 2
		while {![regexp {\[.*\]} [lindex $lmi $j]]} {
			append town " " [lindex $lmi $j]
			incr j
		}

		set fullType [lindex $lmi $j]
		set type [string map {\[ "" \] "" , ""} $fullType]
		lappend town $type
	}

	dict set ret Town $town

	# Population, Race
	set lmi [lindex $lm $i]
	if {$lmi eq ""} {return $ret} ;# done
	incr i

	regexp {([[:digit:]]+) +peasants +\(([^)]+)\)} $lmi -> pop race
	if {![info exists pop]} {
		puts "Could not parse region race token '$lmi' in region $v"
		exit
	}
	dict set ret Population $pop
	dict set ret Race $race

	# Max Taxes
	dict set ret MaxTax [string map {\$ "" . ""} [lindex $lm $i]]

	return $ret
}

# fields - originally comma separated list of a bunch of stuff
# return index of first item (after flags)
proc unitItemsIdx {fields} {
	# field 0 - name (and report type)
	# field 1 - faction, sometimes...
	# fields 2+ flags
	set i 1
	while {![regexp {\[[[:alnum:]]{4}\]} [lindex $fields $i]]} {
		incr i
		if {$i > [llength $fields]} {
			puts "Error in $fields"
			exit
		}
	}
	return $i
}

proc repairItemList {l} {
	set ret ""
	foreach i $l {
		if {[string is integer [lindex $i 0]]} {
			lappend ret [list [lindex $i 0] [lrange $i 1 end-1] [lindex $i end]]
		} else {
			lappend ret [list 1 [lrange $i 0 end-1] [lindex $i end]]
		}
	}
	return $ret
}

proc fixSkills {skills} {
	set ret ""
	foreach s $skills {
		set name [lrange $s 0 end-3]
		set abbr [string map {"[" "" "]" ""} [lindex $s end-2]]
		set lvl  [lindex $s end-1]
		set pts  [string map {"(" "" ")" ""} [lindex $s end]]

		lappend ret [list $name $abbr $lvl $pts]
	}

	return $ret
}

proc parseUnit {v} {
	# what sort of report is this
	set quality own
	if {[lindex $v 0] == "-"} {
		set quality foreign
	}

	# get unit name
	set comma [string first "," $v]
	set n [string range $v 2 $comma-1]

	set groups [split $v "."]

	set group0 [split [lindex $groups 0] ","]
	set itemIdx [unitItemsIdx $group0]
	set items [lrange $group0 $itemIdx end]
	set items [repairItemList $items]

	set u [dict create Name $n Desc {} Report $quality Items $items]

	# group 3 - skills
	if {$quality eq "own"} {
		set group3 [string map {"\n" " "} [lindex $groups 3]]
		set skills [split [lrange $group3 1 end] ","]

		dict set u Skills [fixSkills $skills]
	}

	return $u
}

proc getRegion {f} {
	set v [getSection $f]
	if {$v eq "Orders Template (Long Format):"} {
		return ""
	}
	set region [parseRegion $v]
	set ::nextLine "" ;# clear the -----

	# weather
	set v [getSection $f]
	regexp {was (.*) last month; it will be (.*) next} $v -> old new
	dict set region WeatherOld $old
	dict set region WeatherNew $new

	# wages
	set v [getSection $f]
	dict set region Wage    [string map {\$ ""} [lindex $v 1]]
	dict set region MaxWage [string map {\$ "" \) "" . ""} [lindex $v 3]]

	# wants
	set v [getSection $f]
	dict set region Units {}

	# for sale
	set v [getSection $f]

	# entertainment
	set v [getSection $f]
	if {[lindex $v 0] eq "Entertainment"} {
		# products
		set v [getSection $f]
	}
	set v [string map {"\n" ""} $v]
	dict set region Products [split [string trimright $v "."] ","]

	# exits
	set v [getSection $f]
	set v [string map {\[ "" \] ""} $v]
	set exits [split [lrange $v 1 end] "."]

	set eout ""
	foreach e $exits {
		if {$e eq ""} continue
		if {![string is list $e]} {
			puts "odd '$e'"
			puts "exits '$exits'"
			puts "region '$region'"
			exit
		}

		lappend eout [lindex $e 0]
		set terrain  [lindex $e 2]

		if {[regexp {<underworld>} $e]} {
			set t [join [lrange $e 3 4]]
			set e [lreplace $e 3 4 $t]
		}

		set loc      [lindex $e 3]
		regexp {\(([[:digit:]]+),([[:digit:]]+),?([[:digit:]]+)?} \
		   $loc -> x y z

		if {![info exists x]} {
			puts "loc '$loc'"
			puts "e '$e'"
			puts "region '$region'"
			exit
		}

		set lxy [list $x $y]
		if {$z ne ""} {lappend lxy $z}

		set ci [lsearch $e "contains"]
		if {$ci == -1} {
			set exRegion [lrange $e 5 end]
			set town ""
		} else {
			set exRegion [string trimright [lrange $e 5 $ci-1] ","]

			set townName [lrange $e $ci+1 end-1]
			set townType [string trimright [lindex $e end] "."]

			set town [list $townName $townType]
		}

		lappend eout [list Location $lxy Terrain $terrain Town $town \
		  Region $exRegion]
	}
	dict set region Exits $eout

	# units
	set hadBuilding 0
	set oldNextLine $::nextLine
	set filePtr [tell $f]
	set v [getSection $f]
	while {[lindex $v 0] eq "-" ||
	       [lindex $v 0] eq "*" ||
	       [lindex $v 0] eq "+"} {

		# check that building reports are last
		if {[lindex $v 0] eq "+"} {
			set hadBuilding 1

			set lines [split [string trimright $v "."] "."]
			set hdr [lindex $lines 0]
			regexp {\+ ([^:]+) : (.*)} $hdr -> oname odesc
			set object [dict create Name $oname]

			if {[llength $lines] == 1} {
				dict lappend region Objects $object

				set oldNextLine $::nextLine
				set filePtr [tell $f]

				set v [getSection $f]

				continue
			}

			set i 1
			set j 2
			while {$j < [llength $lines]} {
				while {$j < [llength $lines] &&
				       [lindex [lindex $lines $j] 0] ne "*" &&
				       [lindex [lindex $lines $j] 0] ne "-"} {
					incr j
				}

				set v1 [join [lrange $lines $i $j-1] "."]
				set u [parseUnit $v1]

				dict lappend object Units $u

				set i $j
				incr j
			}

			dict lappend region Objects $object

			set oldNextLine $::nextLine
			set filePtr [tell $f]

			set v [getSection $f]
			continue
		}

		if {$hadBuilding} {
			puts "Error building intermixed with units in '$v'"
			exit
		}

		set u [parseUnit $v]

		dict lappend region Units $u

		set oldNextLine $::nextLine
		set filePtr [tell $f]

		set v [getSection $f]
	}

	seek $f $filePtr
	set ::nextLine $oldNextLine

	return $region
}

proc parseFile {f} {
	# initial headers
	set v [getSection $f]
	# Atlantis Report For:

	set v [getSection $f]
	# Faction Name (number) (War n,Trade n, Magic n)

	set v [getSection $f]
	puts "Month [string map {"," ""} $v]"

	# skip all the events
	set v [getSection $f]
	while {![regexp {^Unclaimed silver:} $v]} {
		set v [getSection $f]
	}

	# unclaimed silver

	# regions
	set regions ""
	set regionData [getRegion $f]
	while {$regionData ne ""} {
		lappend regions $regionData
		set regionData [getRegion $f]
	}

	# orders template
	# faction number and pass
	set v [getSection $f]

	# orders
	set v [getSection $f]
	set loc [lindex $v 2]
	set xy [string map {( "" ) "" , " "} $loc]

	while {$xy ne ""} {
		set xy [doRegionOrders $f regions $xy]
	}

	# done
	puts "Regions [list $regions]"
}

################
if {![info exists debug]} {
	if {$argc != 1} {
		puts "Usage $argv0 <filename>"
		exit
	}

	set f [open [lindex $argv 0]]
	parseFile $f
}

