#
# Prototype to test Richard and radar-mafia's radar designs.
#
# v1: Modular - 7 Nov. 2017
# v2: Decoupled via emesary - 8 Nov 2017
#
#
# Notice that everything below test code line, is not decoupled, nor optimized in any way.
# Also notice that most comments are old and not updated.
#
# Needs rcs.nas and vector.nas. Nothing else.
#
# GPL 2.0


var AIR = 0;
var MARINE = 1;
var SURFACE = 2;
var ORDNANCE = 3;

var GEO = 0;
var GPS = 1;

var FALSE = 0;
var TRUE = 1;

var knownShips = {
    "missile_frigate":       nil,
    "frigate":       nil,
    "USS-LakeChamplain":     nil,
    "USS-NORMANDY":     nil,
    "USS-OliverPerry":     nil,
    "USS-SanAntonio":     nil,
};

var VectorNotification = {
    new: func(type) {
        var new_class = emesary.Notification.new(type, rand());
        new_class.updateV = func (vector) {
	    	me.vector = vector;
	    	return me;
	    };
        return new_class;
    },
};

AIToNasal = {
# convert AI property tree to Nasal vector
# will send notification when some is updated (emesary?)
# listeners for adding/removing AI nodes.
# very slow loop (10 secs)
# updates AIContacts, does not replace them. (yes will make slower, but solves many issues. Can divide workload over 2 frames.)
#
# Attributes:
#   fullContactVector of AIContacts
#   index keys for fast locating: callsign, model-path??
	new: func {
		me.prop_AIModels = props.globals.getNode("ai/models");
		me.vector_aicontacts = [];
		me.callInProgress = 0;
		me.updateInProgress = 0;
		me.lookupCallsign = {};
		me.AINotification = VectorNotification.new("AINotification");
		me.AINotification.updateV(me.vector_aicontacts);

		setlistener("/ai/models/model-added", func me.callReadTree());
		setlistener("/ai/models/model-removed", func me.callReadTree());
		me.loop = maketimer(30, me, func me.callReadTree());
		me.loop.start();
	},

	callReadTree: func {
		#print("NR: listenr called");
		if (!me.callInProgress) {
			# multiple fast calls migth be done to this method, by delaying the propagation we don't have to call readTree for each call.
			me.callInProgress = 1;
			settimer(func me.readTree(), 0.15);
		}
	},

	readTree: func {
		#print("NR: readtree called");
		me.callInProgress = 0;

		me.vector_raw = me.prop_AIModels.getChildren();
		me.lookupCallsignRaw = {};

		foreach (me.prop_ai;me.vector_raw) {
			me.prop_valid = me.prop_ai.getNode("valid");
			if (me.prop_valid == nil or !me.prop_valid.getValue() or me.prop_ai.getNode("impact") != nil) {
				# its either not a valid entity or its a impact report.
                continue;
            }
            me.type = AIR;

            # find short model xml name: (better to do here, even though its slow) [In viggen its placed inside the property tree, which leads to too much code to update it when tree changes]
            me.name_prop = me.prop_ai.getName();
            me.model = me.prop_ai.getNode("sim/model/path");
            if (me.model != nil) {
              	me.path = me.model.getValue();

              	me.model = split(".", split("/", me.path)[-1])[0];
              	me.model = me.remove_suffix(me.model, "-model");
              	me.model = me.remove_suffix(me.model, "-anim");
            } else {
            	me.model = "";
            }

            # position type
            me.pos_type = nil;
            me.pos = me.prop_ai.getNode("position");
		    me.x = me.pos.getNode("global-x");
		    me.y = me.pos.getNode("global-y");
		    me.z = me.pos.getNode("global-z");
		    if(me.x == nil or me.y == nil or me.z == nil) {
		    	me.alt = me.pos.getNode("altitude-ft");
		    	me.lat = me.pos.getNode("latitude-deg");
		    	me.lon = me.pos.getNode("longitude-deg");	
		    	if(me.alt == nil or me.lat == nil or me.lon == nil) {
			      	continue;
				}
			    me.pos_type = GPS;
			    me.aircraftPos = geo.Coord.new().set_latlon(me.lat.getValue(), me.lon.getValue(), me.alt.getValue()*FT2M);
		    } else {
		    	me.pos_type = GEO;
		    	me.aircraftPos = geo.Coord.new().set_xyz(me.x.getValue(), me.y.getValue(), me.z.getValue());
		    	me.alt = me.aircraftPos.alt();
		    }
		    
		    me.prop_speed = me.prop_ai.getNode("velocities/true-airspeed-kt");
		    me.prop_ord   = me.prop_ai.getNode("missile");

		    # determine type. Unsure if this should be done here, or in Radar.
		    #   For here: PRO better performance. CON might change in between calls to reread tree, and dont have doppler to determine air from ground.
            if (me.name_prop == "carrier" or me.name_prop == "ship") {
            	me.type = MARINE;
            } elsif (me.name_prop == "groundvehicle") {
            	me.type = SURFACE;
            } elsif (me.alt < 3.0) {
            	me.type = MARINE;
            } elsif (me.model != nil and contains(knownShips, me.model)) {
				me.type = MARINE;
            } elsif (me.prop_ord != nil) {
            	me.type = ORDNANCE;
            } elsif (me.prop_speed != nil and me.prop_speed.getValue() < 75) {
            	me.type = nil;# to be determined later by doppler in Radar
            }
            
            #append(me.vector_aicontacts_raw, me.aicontact);
            me.callsign = me.prop_ai.getNode("callsign");
            if (me.callsign == nil) {
            	me.callsign = "";
            } else {
            	me.callsign = me.callsign.getValue();
            }

            me.aicontact = AIContact.new(me.prop_ai, me.type, me.model, me.callsign, me.pos_type);#AIcontact needs 2 calls to work. new() [cheap] and init() [expensive]. Only new is called here, updateVector will do init().

            me.signLookup = me.lookupCallsignRaw[me.callsign];
            if (me.signLookup == nil) {
            	me.signLookup = [me.aicontact];
            } else {
            	append(me.signLookup, me.aicontact);
            }
            me.lookupCallsignRaw[me.callsign] = me.signLookup;
		}

		if (!me.updateInProgress) {
			me.updateInProgress = 1;
			settimer(func me.updateVector(), 0);
		}
	},

	remove_suffix: func(s, x) {
	      me.len = size(x);
	      if (substr(s, -me.len) == x)
	          return substr(s, 0, size(s) - me.len);
	      return s;
	},

	updateVector: func {
		# lots of iterating in this method. But still fast since its done without propertytree.
		me.updateInProgress = 0;
		me.callsignKeys = keys(me.lookupCallsignRaw);
		me.lookupCallsignNew = {};
		me.vector_aicontacts = [];
		foreach(me.callsignKey; me.callsignKeys) {
			me.callsignsRaw = me.lookupCallsignRaw[me.callsignKey];
			me.callsigns    = me.lookupCallsign[me.callsignKey];
			if (me.callsigns != nil) {
				foreach(me.newContact; me.callsignsRaw) {
					me.oldContact = me.containsVectorContact(me.callsigns, me.newContact);
					if (me.oldContact != nil) {
						me.oldContact.update(me.newContact);
						me.newContact = me.oldContact;
					}
					append(me.vector_aicontacts, me.newContact);
					if (me.lookupCallsignNew[me.callsignKey]==nil) {
						me.lookupCallsignNew[me.callsignKey] = [me.newContact];
					} else {
						append(me.lookupCallsignNew[me.callsignKey], me.newContact);
					}
					me.newContact.init();
				}
			} else {
				me.lookupCallsignNew[me.callsignKey] = me.callsignsRaw;
				foreach(me.newContact; me.callsignsRaw) {
					append(me.vector_aicontacts, me.newContact);
					me.newContact.init();
				}
			}
		}
		me.lookupCallsign = me.lookupCallsignNew;
		#print("NR: update called "~size(me.vector_aicontacts));
		emesary.GlobalTransmitter.NotifyAll(me.AINotification.updateV(me.vector_aicontacts));
	},

	containsVectorContact: func (vec, item) {
		foreach(test; vec) {
			if (test.equals(item)) {
				return test;
			}
		}
		return nil;
	},
};








Contact = {
# Attributes:
	getCoord: func {
	   	return geo.Coord.new();
	},
};






AIContact = {
# Attributes:
#   replaceNode() [in AI tree]
	new: func (prop, type, model, callsign, pos_type) {
		var c = {parents: [AIContact, Contact]};

		# general:
		c.prop     = prop;
		c.type     = type;
		c.model    = model;
		c.callsign = callsign;
		c.pos_type = pos_type;
		c.needInit = 1;

		# active radar:
		c.blepTime = 0;
		c.coordFrozen = geo.Coord.new();

    	return c;
	},

	init: func {
		if (me.needInit == 0) {
			# init is expensive. Avoid it not needed.
			return;
		}
		me.needInit = 0;
		# read all properties and store them for fast lookup.
		me.pos = me.prop.getNode("position");
		me.ori = me.prop.getNode("orientation");
		me.x = me.pos.getNode("global-x");
    	me.y = me.pos.getNode("global-y");
    	me.z = me.pos.getNode("global-z");
    	me.alt = me.pos.getNode("altitude-ft");
    	me.lat = me.pos.getNode("latitude-deg");
    	me.lon = me.pos.getNode("longitude-deg");
    	me.heading = me.ori.getNode("true-heading-deg");
	},

	update: func (newC) {
		if (me.prop.getPath() != newC.prop.getPath()) {
			me.prop = newC.prop;
			me.needInit = 1;
		}
		me.type = newC.type;
		me.model = newC.model;
		me.callsign = newC.callsign;
	},

	equals: func (item) {
		if (item.prop.getName() == me.prop.getName() and item.type == me.type and item.model == me.model and item.callsign == me.callsign) {
			return TRUE;
		}
		return FALSE;
	},

	getCoord: func {
		if (me.pos_type = GEO) {
	    	me.coord = geo.Coord.new().set_xyz(me.x.getValue(), me.y.getValue(), me.z.getValue());
	    	return me.coord;
	    } else {
	    	if(me.alt == nil or me.lat == nil or me.lon == nil) {
		      	return geo.Coord.new();
		    }
		    me.coord = geo.Coord.new().set_latlon(me.lat.getValue(), me.lon.getValue(), me.alt.getValue()*FT2M);
		    return me.coord;
	    }	
	},

	getDeviationPitch: func {
		me.getCoord();
		me.pitch = vector.Math.getPitch(geo.aircraft_position(), me.coord);
		return me.pitch - getprop("orientation/pitch-deg");
	},

	getDeviationHeading: func {
		me.getCoord();
		return geo.normdeg180(geo.aircraft_position().course_to(me.coord)-getprop("orientation/heading-deg"));
	},

	getRangeDirect: func {# meters
		me.getCoord();
		return geo.aircraft_position().direct_distance_to(me.coord);
	},

	blep: func (time, azimuth, strength) {
		me.blepTime = time;
		me.coordFrozen = me.getCoord();
		me.headingFrozen = me.getHeading();
		me.azi = azimuth;
		me.strength = strength;
	},

	getDeviationPitchFrozen: func {
		me.pitch = vector.Math.getPitch(geo.aircraft_position(), me.coordFrozen);
		return me.pitch - getprop("orientation/pitch-deg");
	},

	getDeviationHeadingFrozen: func {
		return geo.normdeg180(geo.aircraft_position().course_to(me.coordFrozen)-getprop("orientation/heading-deg"));
	},

	getRangeDirectFrozen: func {# meters
		return geo.aircraft_position().direct_distance_to(me.coordFrozen);
	},

	getRangeFrozen: func {# meters
		return geo.aircraft_position().distance_to(me.coordFrozen);
	},

	getHeading: func {
		if (me.heading == nil) {
			return 0;
		}
		return me.heading.getValue();
	},

	getHeadingFrozen: func {
		if (me.azi) {
			return me.headingFrozen;
		} else {
			return nil;
		}
	},
};





###GPSContact:
# inherits from Contact
#
# Attributes:
#   coord

###RadarContact:
# inherits from AIContact
#
# Attributes:
#   isPainted()  [asks parent radar is it the one that is painted]
#   isDetected() [asks parent radar if it still is in limitedContactVector]

###LinkContact:
# inherits from AIContact
#
# Attributes:
#   isPainted()  [asks parent radar is it the one that is painted]
#   link to linking aircraft AIContact
#   isDetected() [asks parent radar if it still is in limitedContactVector]













Radar = {
# master radar class
#
# Attributes:
#   on/off
#   limitedContactVector of RadarContacts
	enabled: TRUE,
};

NoseRadar = {
	new: func (range_m, radius, rate) {
		var nr = {parents: [NoseRadar, Radar]};

		nr.forRadius_deg  = radius;
		nr.forDist_m      = range_m;#range setting
		nr.vector_aicontacts = [];
		nr.vector_aicontacts_for = [];
		nr.timer          = maketimer(rate, nr, func nr.scanFOR());

		nr.NoseRadarRecipient = emesary.Recipient.new("NoseRadarRecipient");
		nr.NoseRadarRecipient.radar = nr;
		nr.NoseRadarRecipient.Receive = func(notification) {
	        if (notification.NotificationType == "AINotification") {
	        	printf("NoseRadar recv: %s", notification.NotificationType);
	            if (me.radar.enabled == 1) {
	    		    me.radar.vector_aicontacts = notification.vector;
	    	    }
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        return emesary.Transmitter.ReceiptStatus_NotProcessed;
	    };
		emesary.GlobalTransmitter.Register(nr.NoseRadarRecipient);
		nr.FORNotification = VectorNotification.new("FORNotification");
		nr.FORNotification.updateV(nr.vector_aicontacts_for);
		nr.timer.start();
		return nr;
	},

	scanFOR: func {
		#iterate:
		# check direct distance
		# check field of regard
		# sort in bearing?
		# called every approx 5 seconds
		me.vector_aicontacts_for = [];
		foreach(contact ; me.vector_aicontacts) {
			if (contact.getRangeDirect() > me.forDist_m) {
				continue;
			} elsif (math.abs(contact.getDeviationHeading()) > me.forRadius_deg) {
				continue;
			} elsif (math.abs(contact.getDeviationPitch()) > me.forRadius_deg) {
				continue;
			}
			append(me.vector_aicontacts_for, contact);
		}		
		emesary.GlobalTransmitter.NotifyAll(me.FORNotification.updateV(me.vector_aicontacts_for));
		#print("In Field of Regard: "~size(me.vector_aicontacts_for));
	},

	more: func {
		#test method
		me.forDist_m      *= 2;
		me.scanFOR();
	},

	less: func {
		#test method
		me.forDist_m      *= 0.5;
		me.scanFOR();
	},
};








var REVERSE = 0;
var LOOP    = 1;

var NONE = 0;
var SOFT = 1;
var HARD = 2;

var max_soft_locks = 8;
var time_to_keep_bleps = 6;
var time_to_fadeout_bleps = 5;
var time_till_lose_lock = 0.5;
var time_till_lose_lock_soft = 4.5;
var sam_radius = 15;
var max_tws_range = 30;# these 2 should be determined from RCS instead.
var max_lock_range = 40;

#air scan modes:
var TRACK_WHILE_SCAN = 2;# Gives velocity, angle, azimuth and range. Multiple soft locks. Short range. Fast.
#var SINGLE_TARGET_TRACK = 4;# focus on a contact. hard lock. Good for identification. Mid range.
var RANGE_WHILE_SEARCH = 1;# Gives range/angle info. Long range. Narrow bars.
#var SITUATION_AWARENESS_MODE = 3;# submode of RWS/TWS. A contact can be followed/selected while scan still being done that can show other bleps nearby.
var VELOCITY_SEARCH = 0;# gives positive closure rate. Long range.



ActiveDiscRadar = {
# inherits from Radar
# will check range, field of view/regard, ground occlusion and FCS.
# will also scan a field. And move that scan field as appropiate for scan mode.
# do not use directly, inherit and instance it.
# fast loop
#
# Attributes:
#   contact selection(s) of type Contact
#   soft/hard lock
#   painted (is the hard lock) of type Contact
	new: func () {
		var ar = {parents: [ActiveDiscRadar, Radar]};
		ar.timer          = maketimer(1, ar, func ar.loop());
		ar.lock           = NONE;# NONE, SOFT, HARD
		ar.locks          = [];
		ar.follow         = [];
		ar.vector_aicontacts_for = [];
		ar.vector_aicontacts_bleps = [];
		ar.scanMode       = RANGE_WHILE_SEARCH;
		ar.scanType       = AIR;
		ar.directionX     = 1;
		ar.patternBar     = 0;
		ar.barOffset      = 0;

		# these should be init in the actuaal radar:
		ar.discSpeed_dps  = 1;
		ar.fovRadius_deg  = 1;
		ar.calcLoop();
		ar.calcBars();
		ar.pattern        = [-1,1,[0]];#6/8 bars
		
		
		ar.posE           = ar.bars[ar.pattern[2][ar.patternBar]];
		ar.posH           = ar.pattern[0];

		ar.lockX = 1;
		ar.lockY = 1;
		ar.posHLast = ar.posH;

		# emesary
		ar.ActiveDiscRadarRecipient = emesary.Recipient.new("ActiveDiscRadarRecipient");
		ar.ActiveDiscRadarRecipient.radar = ar;
		ar.ActiveDiscRadarRecipient.Receive = func(notification) {
	        if (notification.NotificationType == "FORNotification") {
	        	printf("DiscRadar recv: %s", notification.NotificationType);
	            if (me.radar.enabled == 1) {
	    		    me.radar.vector_aicontacts_for = notification.vector;
	    		    me.radar.forWasScanned();
	    	    }
	            return emesary.Transmitter.ReceiptStatus_OK;
	        }
	        return emesary.Transmitter.ReceiptStatus_NotProcessed;
	    };
		emesary.GlobalTransmitter.Register(ar.ActiveDiscRadarRecipient);
		ar.timer.start();
    	return ar;
	},

	calcBars: func {
		# must be called each time fovRadius_deg is changed.
		me.bars           = [-me.fovRadius_deg*7,-me.fovRadius_deg*5,-me.fovRadius_deg*3,-me.fovRadius_deg,me.fovRadius_deg,me.fovRadius_deg*3,me.fovRadius_deg*5,me.fovRadius_deg*7];
	},

	calcLoop: func {
		me.loopSpeed      = 1/(me.discSpeed_dps/(me.fovRadius_deg*2));
		me.timer.restart(me.loopSpeed);
		#print("loop: "~me.loopSpeed);
	},

	loop: func {
		me.moveDisc();
		me.scanFOV();
		if (me.lock == HARD) {
			me.purgeLock(time_till_lose_lock);
		} else {
			me.purgeLocks(time_till_lose_lock_soft);
		}
	},

	forWasScanned: func {
		me.vector_aicontacts_bleps_tmp = [];
		me.elapsed = getprop("sim/time/elapsed-sec");
		foreach(contact ; me.vector_aicontacts_bleps) {
			if (me.elapsed - contact.blepTime < time_to_keep_bleps) {
				append(me.vector_aicontacts_bleps_tmp, contact);
			}
		}
		me.vector_aicontacts_bleps = me.vector_aicontacts_bleps_tmp;
		if (size(me.follow) > 0 and !me.containsVector(me.vector_aicontacts_bleps, me.follow[0])) {
			me.follow = [];
		}
	},

	purgeLocks: func (time) {
		me.locks_tmp = [];
		me.elapsed = getprop("sim/time/elapsed-sec");
		foreach(contact ; me.locks) {
			if (me.elapsed - contact.blepTime < time) {
				append(me.locks_tmp, contact);
			}
		}
		me.locks = me.locks_tmp;
		if (size(me.locks) == 0) {
			me.lock = NONE;
		}
		if (size(me.follow) > 0 and !me.containsVector(me.vector_aicontacts_bleps, me.follow[0])) {
			me.follow = [];
		}
	},

	purgeLock: func (time) {
		if (size(me.locks) == 1) {
			me.elapsed = getprop("sim/time/elapsed-sec");
			if (me.elapsed - me.locks[0].blepTime > time) {
				me.locks = [];
				me.lock = NONE;
				me.follow = [];
			} elsif (me.locks[0].getRangeDirect()*M2NM > max_lock_range) {
				me.locks = [];
				me.lock = NONE;
			}
		} elsif (size(me.locks) == 0) {
			me.lock = NONE;
		}
	},

	containsVector: func (vec, item) {
		foreach(test; vec) {
			if (test == item) {
				return TRUE;
			}
		}
		return FALSE;
	},

	vectorIndex: func (vec, item) {
		me.i = 0;
		foreach(test; vec) {
			if (test == item) {
				return me.i;
			}
			me.i += 1;
		}
		return -1;
	},

	moveDisc: func {
		# move the FOV inside the FOR
		#me.acPitch = getprop("orientation/pitch-deg");
		me.reset = 0;
		me.step = 1;
		me.pattern_move = [me.pattern[0],me.pattern[1],me.pattern[2]];# we move on a temp pattern, so we can revert to normal scan mode, after lock/follow.
		if (size(me.follow) > 0 and me.lock != HARD) {
			# scan follows selection (SAM)
			me.pattern_move[0] = me.follow[0].getDeviationHeadingFrozen()-sam_radius;
			me.pattern_move[1] = me.follow[0].getDeviationHeadingFrozen()+sam_radius;
			if (me.pattern_move[0] < -me.forRadius_deg) {
				me.pattern_move[0] = -me.forRadius_deg;
			}
			if (me.pattern_move[1] > me.forRadius_deg) {
				me.pattern_move[1] = me.forRadius_deg;
			}
		}
		if (me.lock != HARD) {
			# Normal scan
			me.reverted = 0;
			if (getprop("sim/time/delta-sec") > me.loopSpeed) {
				# hack for slow FPS
				me.step = 2;
			}		
			me.posH_new  = me.posH+me.directionX*me.fovRadius_deg*2*me.step;
			me.polarDist = math.sqrt(me.posH_new*me.posH_new+me.posE*me.posE);
			if (me.polarDist > me.forRadius_deg or (me.directionX==1 and me.posH > me.pattern_move[1]) or (me.directionX==-1 and me.posH < me.pattern_move[0])) {
				me.patternBar +=1;
				me.directionX *= -1;
				me.reverted = 1;
				me.checkBarValid();
				me.posE = me.bars[me.pattern_move[2][me.patternBar]]+me.barOffset*me.fovRadius_deg*2;
				if (me.directionX == 1) {
					me.posH = me.pattern_move[0]+me.fovRadius_deg;
				} else {
					me.posH = me.pattern_move[1]-me.fovRadius_deg;
				}
				me.polarDist = math.sqrt(me.posH*me.posH+me.posE*me.posE);
				if (me.polarDist > me.forRadius_deg) {
					me.posH = -math.cos(math.asin(clamp(me.posE/me.pattern_move[1],-1,1)))*me.pattern_move[1]*me.directionX+me.directionX*me.fovRadius_deg;# disc set at beginning of new bar.
				}
				#if (me.posE-getprop("orientation/pitch-deg") > me.forRadius_deg) {
					#is this realy how it works when you pitch much down?
				#	me.posE = me.forRadius_deg-getprop("orientation/pitch-deg");
				#} elsif (me.posE-getprop("orientation/pitch-deg") < -me.forRadius_deg) {
				#	me.posE = getprop("orientation/pitch-deg")+me.forRadius_deg;
				#}
			} else {
				me.posH = me.posH_new;
			}
		} else {
			# lock scan
			me.posH_n = me.locks[0].getDeviationHeadingFrozen()+me.lockX*me.fovRadius_deg*0.5;
			me.posE_n = me.locks[0].getDeviationPitchFrozen()+me.lockY*me.fovRadius_deg*0.5;
			if (me.forRadius_deg >= math.sqrt(me.posH_n*me.posH_n+me.posE_n*me.posE_n)) {
				me.posH = me.posH_n;
				me.posE = me.posE_n;
			}
			me.lockX *= -1;
			if (me.lockX == -1) {
				me.lockY *= -1;
			}
		}
		#printf("scanning %04.1f, %04.1f", me.posH, me.posE);
	},

	checkBarValid: func {
		if (me.patternBar > size(me.pattern_move[2])-1) {
			me.patternBar = 0;
			me.reset = 1;
		}
	},

	scanFOV: func {
		#iterate:
		# check sensor field of view
		# check Terrain
		# check Doppler
		# due to FG Nasal update rate, we consider FOV square.
		# only detect 1 contact, even if more are present.
		foreach(contact ; me.vector_aicontacts_for) {
			me.contactPosH = contact.getDeviationHeading();
			me.contactPosE = contact.getDeviationPitch();
			if (me.contactPosE < me.posE+me.fovRadius_deg and me.contactPosE > me.posE-me.fovRadius_deg) {
				# in correct elevation for detection
				me.doDouble = me.step == 2 and me.reverted == 0;
				if (!me.doDouble and me.contactPosH < me.posH+me.fovRadius_deg and me.contactPosH > me.posH-me.fovRadius_deg) {
					# detected
					#todo: check RCS, Terrain, Doppler here.
					if (me.registerBlep(contact)) {
						#print("detect-1 "~contact.callsign);
						break;
					}
				} elsif (me.doDouble and me.directionX == 1 and me.contactPosH < me.posH+me.fovRadius_deg and me.contactPosH > me.posHLast+me.fovRadius_deg) {
					# detected
					if (me.registerBlep(contact)) {
						#print("detect-1 "~contact.callsign);
						break;
					}
				} elsif (me.doDouble and me.directionX == -1 and me.contactPosH < me.posHLast-me.fovRadius_deg and me.contactPosH > me.posH-me.fovRadius_deg) {
					# detected
					if (me.registerBlep(contact)) {
						#print("detect-1 "~contact.callsign);
						break;
					}
				}
			}
		}
		me.posHLast = me.posH;
	},

	registerBlep: func (contact) {
		me.strength = targetRCSSignal(contact.getCoord(), contact.model, contact.ori.getNode("true-heading-deg").getValue(), contact.ori.getNode("pitch-deg").getValue(), contact.ori.getNode("roll-deg").getValue());
		if (me.strength > contact.getRangeDirect()) {
			contact.blep(getprop("sim/time/elapsed-sec"), me.lock==HARD or (me.scanMode == TRACK_WHILE_SCAN and contact.getRangeDirect() < max_tws_range*NM2M), me.strength);
			if (me.lock != HARD) {
				if (!me.containsVector(me.vector_aicontacts_bleps, contact)) {
					append(me.vector_aicontacts_bleps, contact);
				}
				if (contact.getRangeDirect() < max_tws_range*NM2M and me.scanMode == TRACK_WHILE_SCAN and size(me.locks)<max_soft_locks and !me.containsVector(me.locks, contact)) {
					append(me.locks, contact);
					me.lock = SOFT;
				}
			}
			return 1;
		}
		return 0;
	},
};



###LinkRadar:
# inherits from Radar
# Get contact name from other aircraft, and finds local RadarControl for it.
# no loop. emesary listener on aircraft for link.
#
# Attributes:
#   contact selection(s) of type LinkContact
#   imaginary hard/soft lock
#   link list of contacts of type LinkContact

###RWR:
# inherits from Radar
# will check radar/transponder and ground occlusion.
# will sort according to threat level
# will detect launches (MLW) or (active) incoming missiles (MAW)
# loop (0.5 sec)


var targetRCSSignal = func(targetCoord, targetModel, targetHeading, targetPitch, targetRoll, myRadarDistance_m = 74000, myRadarStrength_rcs = 3.2) {
	#
	# test method. Belongs in rcs.nas.
	#
    #print(targetModel);
    var target_front_rcs = nil;
    if ( contains(rcs.rcs_database,targetModel) ) {
        target_front_rcs = rcs.rcs_database[targetModel];
    } else {
        #return 1;
        target_front_rcs = 5;#rcs.rcs_database["default"];# hardcode defaults to 5 to test with KXTA target scenario.
    }
    var myCoord = geo.aircraft_position();
    var target_rcs = rcs.getRCS(targetCoord, targetHeading, targetPitch, targetRoll, myCoord, target_front_rcs);

    # standard formula
    var currMaxDist = myRadarDistance_m/math.pow(myRadarStrength_rcs/target_rcs, 1/4);
    return currMaxDist;
}


#troubles:
# rescan of ai tree, how to equal same aircraft with new name (COMPARE: callsign, sign, name, model-name)
# doppler only in a2a mode
# 

# TODO:




























#############################
# test code below this line #
#############################





















RadarViewPPI = {
# implements radar/RWR display on CRT/MFD
# also slew cursor to select contacts.
# fast loop
#
# Attributes:
#   link to Radar
#   link to FireControl
	new: func {
		var window = canvas.Window.new([256, 256],"dialog")
				.set('x', 256)
                .set('title', "Radar PPI");
		var root = window.getCanvas(1).createGroup();
		window.getCanvas(1).setColorBackground(0,0,0);
		me.rootCenter = root.createChild("group")
				.setTranslation(128,256);
		me.rootCenterBleps = root.createChild("group")
				.setTranslation(128,256);
		me.sweepDistance = 128/math.cos(30*D2R);
		me.sweep = me.rootCenter.createChild("path")
				.moveTo(0,0)
				.vert(-me.sweepDistance)
				.setStrokeLineWidth(2.5)
				.setColor(1,1,1);
		me.text = root.createChild("text")
	      .setAlignment("left-top")
      	  .setFontSize(12, 1.0)
	      .setColor(1, 1, 1);
	    me.text2 = root.createChild("text")
	      .setAlignment("left-top")
      	  .setFontSize(12, 1.0)
      	  .setTranslation(0,15)
	      .setColor(1, 1, 1);
	    me.text3 = root.createChild("text")
	      .setAlignment("left-top")
      	  .setFontSize(12, 1.0)
      	  .setTranslation(0,30)
	      .setColor(1, 1, 1);
		me.loop();
	},

	loop: func {
		me.sweep.setRotation(exampleRadar.posH*D2R);
		me.elapsed = getprop("sim/time/elapsed-sec");
		me.rootCenterBleps.removeAllChildren();
		foreach(contact; exampleRadar.vector_aicontacts_bleps) {
			if (me.elapsed - contact.blepTime < 5) {
				me.distPixels = contact.getRangeFrozen()*(me.sweepDistance/nose.forDist_m);

				me.rootCenterBleps.createChild("path")
					.moveTo(0,0)
					.vert(2)
					.setStrokeLineWidth(2)
					.setColor(1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps)
					.setTranslation(-me.distPixels*math.cos(contact.getDeviationHeadingFrozen()*D2R+math.pi/2),-me.distPixels*math.sin(contact.getDeviationHeadingFrozen()*D2R+math.pi/2))
					.update();

				if (exampleRadar.containsVector(exampleRadar.locks, contact)) {
					me.rot = contact.getHeadingFrozen();
					if (me.rot == nil) {
						#can happen in transition between TWS to RWS
					} else {
						me.rot = me.rot-getprop("orientation/heading-deg");
						me.rootCenterBleps.createChild("path")
							.moveTo(-5,-5)
							.vert(10)
							.horiz(10)
							.vert(-10)
							.horiz(-10)
							.moveTo(0,-5)
							.vert(-5)
							.setStrokeLineWidth(1)
							.setColor(exampleRadar.lock == HARD?[1,0,0]:[1,1,0])
							.setTranslation(-me.distPixels*math.cos(contact.getDeviationHeadingFrozen()*D2R+math.pi/2),-me.distPixels*math.sin(contact.getDeviationHeadingFrozen()*D2R+math.pi/2))
							.setRotation(me.rot*D2R)
							.update();
					}
				}
				if (exampleRadar.containsVector(exampleRadar.follow, contact)) {
					me.rootCenterBleps.createChild("path")
						.moveTo(-7,-7)
						.vert(14)
						.horiz(14)
						.vert(-14)
						.horiz(-14)
						.setStrokeLineWidth(1)
						.setColor([0.5,0,1])
						.setTranslation(-me.distPixels*math.cos(contact.getDeviationHeadingFrozen()*D2R+math.pi/2),-me.distPixels*math.sin(contact.getDeviationHeadingFrozen()*D2R+math.pi/2))
						.update();
				}
			}
		}
		if (exampleRadar.patternBar<size(exampleRadar.pattern[2])) {
			# the if is due to just after changing bars and before radar loop has run, patternBar can be out of bounds of pattern.
			me.text.setText(sprintf("Bar %+d    Range %d NM", exampleRadar.pattern[2][exampleRadar.patternBar]<4?exampleRadar.pattern[2][exampleRadar.patternBar]-4:exampleRadar.pattern[2][exampleRadar.patternBar]-3,nose.forDist_m*M2NM));
		}
		me.md = exampleRadar.scanMode==TRACK_WHILE_SCAN?"TWS":"RWS";
		if (size(exampleRadar.follow) > 0 and exampleRadar.lock != HARD) {
			me.md = me.md~"-SAM";
		}
		me.text2.setText(sprintf("Lock=%d (%s)  %s", size(exampleRadar.locks), exampleRadar.lock==NONE?"NONE":exampleRadar.lock==SOFT?"SOFT":"HARD",me.md));
		me.text3.setText(sprintf("Select: %s", size(exampleRadar.follow)>0?exampleRadar.follow[0].callsign:""));
		settimer(func me.loop(), exampleRadar.loopSpeed);
	},
};

RadarViewBScope = {
# implements radar/RWR display on CRT/MFD
# also slew cursor to select contacts.
# fast loop
#
# Attributes:
#   link to Radar
#   link to FireControl
	new: func {
		var window = canvas.Window.new([256, 256],"dialog")
				.set('x', 550)
                .set('title', "Radar B-Scope");
		var root = window.getCanvas(1).createGroup();
		window.getCanvas(1).setColorBackground(0,0,0);
		me.rootCenter = root.createChild("group")
				.setTranslation(128,256);
		me.rootCenterBleps = root.createChild("group")
				.setTranslation(128,256);
		me.sweep = me.rootCenter.createChild("path")
				.moveTo(0,0)
				.vert(-256)
				.setStrokeLineWidth(2.5)
				.setColor(1,1,1);
		
	    me.b = root.createChild("text")
	      .setAlignment("left-center")
      	  .setFontSize(10, 1.0)
      	  .setTranslation(0,100)
	      .setColor(1, 1, 1);
	    me.a = root.createChild("text")
	      .setAlignment("left-center")
      	  .setFontSize(10, 1.0)
      	  .setTranslation(0,150)
	      .setColor(1, 1, 1);
		me.loop();
	},

	loop: func {
		me.sweep.setTranslation(128*exampleRadar.posH/60,0);
		me.elapsed = getprop("sim/time/elapsed-sec");
		me.rootCenterBleps.removeAllChildren();
		foreach(contact; exampleRadar.vector_aicontacts_bleps) {
			if (me.elapsed - contact.blepTime < 5) {
				me.distPixels = contact.getRangeFrozen()*(256/nose.forDist_m);

				me.rootCenterBleps.createChild("path")
					.moveTo(0,0)
					.vert(2)
					.setStrokeLineWidth(2)
					.setColor(1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps)
					.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-me.distPixels)
					.update();
				if (exampleRadar.containsVector(exampleRadar.locks, contact)) {
					me.rot = contact.getHeadingFrozen();
					if (me.rot == nil) {
						#can happen in transition between TWS to RWS
					} else {
						me.rot = me.rot-getprop("orientation/heading-deg")-contact.getDeviationHeadingFrozen();
						me.rootCenterBleps.createChild("path")
							.moveTo(-5,-5)
							.vert(10)
							.horiz(10)
							.vert(-10)
							.horiz(-10)
							.moveTo(0,-5)
							.vert(-5)
							.setStrokeLineWidth(1)
							.setColor(exampleRadar.lock == HARD?[1,0,0]:[1,1,0])
							.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-me.distPixels)
							.setRotation(me.rot*D2R)
							.update();
					}
				}
				if (exampleRadar.containsVector(exampleRadar.follow, contact)) {
					me.rootCenterBleps.createChild("path")
						.moveTo(-7,-7)
						.vert(14)
						.horiz(14)
						.vert(-14)
						.horiz(-14)
						.setStrokeLineWidth(1)
						.setColor([0.5,0,1])
						.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-me.distPixels)
						.update();
				}
			}
		}
		
		var a = 0;
		if (exampleRadar.pattern[1] < 8) {
			a = 1;
		} elsif (exampleRadar.pattern[1] < 20) {
			a = 2;
		} elsif (exampleRadar.pattern[1] < 35) {
			a = 3;
		} elsif (exampleRadar.pattern[1] < 70) {
			a = 4;
		}
		var b = size(exampleRadar.pattern[2]);
		me.b.setText("B"~b);
		me.a.setText("A"~a);
		settimer(func me.loop(), exampleRadar.loopSpeed);
	},
};

RadarViewCScope = {
# implements radar/RWR display on CRT/MFD
# also slew cursor to select contacts.
# fast loop
#
# Attributes:
#   link to Radar
#   link to FireControl
	new: func {
		var window = canvas.Window.new([256, 256],"dialog")
				.set('x', 825)
                .set('title', "Radar C-Scope");
		var root = window.getCanvas(1).createGroup();
		window.getCanvas(1).setColorBackground(0,0,0);
		me.rootCenter = root.createChild("group")
				.setTranslation(128,256);
		me.rootCenter2 = root.createChild("group")
				.setTranslation(0,128);
		me.rootCenterBleps = root.createChild("group")
				.setTranslation(128,128);
		me.sweep = me.rootCenter.createChild("path")
				.moveTo(0,0)
				.vert(-20)
				.setStrokeLineWidth(2.5)
				.setColor(1,1,1);
		me.sweep2 = me.rootCenter2.createChild("path")
				.moveTo(0,0)
				.horiz(20)
				.setStrokeLineWidth(2.5)
				.setColor(1,1,1);
		
	    root.createChild("path")
	       .moveTo(0, 128)
           .arcSmallCW(128, 128, 0, 256, 0)
           .arcSmallCW(128, 128, 0, -256, 0)
           .setStrokeLineWidth(1)
           .setColor(1, 1, 1);
		me.loop();
	},

	loop: func {
		me.sweep.setTranslation(128*exampleRadar.posH/60,0);
		me.sweep2.setTranslation(0, -128*exampleRadar.posE/60);
		me.elapsed = getprop("sim/time/elapsed-sec");
		me.rootCenterBleps.removeAllChildren();
		#me.rootCenterBleps.createChild("path")# thsi will show where the disc is pointed for debug purposes.
		#			.moveTo(0,0)
		#			.vert(2)
		#			.setStrokeLineWidth(2)
		#			.setColor(0.5,0.5,0.5)
		#			.setTranslation(128*exampleRadar.posH/60,-128*exampleRadar.posE/60)
		#			.update();
		foreach(contact; exampleRadar.vector_aicontacts_bleps) {
			if (me.elapsed - contact.blepTime < 5) {
				me.rootCenterBleps.createChild("path")
					.moveTo(0,0)
					.vert(2)
					.setStrokeLineWidth(2)
					.setColor(1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps,1-(me.elapsed - contact.blepTime)/time_to_fadeout_bleps)
					.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-128*contact.getDeviationPitchFrozen()/60)
					.update();
				if (exampleRadar.containsVector(exampleRadar.locks, contact)) {
					me.rootCenterBleps.createChild("path")
						.moveTo(-5,-5)
						.vert(10)
						.horiz(10)
						.vert(-10)
						.horiz(-10)
						.setStrokeLineWidth(1)
						.setColor(exampleRadar.lock == HARD?[1,0,0]:[1,1,0])
						.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-128*contact.getDeviationPitchFrozen()/60)
						.update();
				}
				if (exampleRadar.containsVector(exampleRadar.follow, contact)) {
					me.rootCenterBleps.createChild("path")
						.moveTo(-7,-7)
						.vert(14)
						.horiz(14)
						.vert(-14)
						.horiz(-14)
						.setStrokeLineWidth(1)
						.setColor([0.5,0,1])
						.setTranslation(128*contact.getDeviationHeadingFrozen()/60,-128*contact.getDeviationPitchFrozen()/60)
						.update();
				}
			}
		}
		

		settimer(func me.loop(), exampleRadar.loopSpeed);
	},
};

var clamp = func(v, min, max) { v < min ? min : v > max ? max : v }
RadarViewAScope = {
# implements radar/RWR display on CRT/MFD
# also slew cursor to select contacts.
# fast loop
#
# Attributes:
#   link to Radar
#   link to FireControl
	new: func {
		var window = canvas.Window.new([256, 256],"dialog")
				.set('x', 825)
				.set('y', 350)
                .set('title', "Radar A-Scope");
		var root = window.getCanvas(1).createGroup();
		window.getCanvas(1).setColorBackground(0,0,0);
		me.rootCenter = root.createChild("group")
				.setTranslation(0,250);
		me.line = [];
		for (var i = 0;i<256;i+=1) {
			append(me.line, me.rootCenter.createChild("path")
					.moveTo(0,0)
					.vert(300)
					.setStrokeLineWidth(1)
					.setColor(1,1,1));
		}
		me.values = setsize([], 256);
		me.loop();
	},

	loop: func {
		for (var i = 0;i<256;i+=1) {
			me.values[i] = 0;
		}
		me.elapsed = getprop("sim/time/elapsed-sec");
		foreach(contact; exampleRadar.vector_aicontacts_bleps) {
			if (me.elapsed - contact.blepTime < 5) {
				me.range = contact.getRangeDirectFrozen();
				if (me.range==0) me.range=1;
				me.distPixels = 2/math.pow(me.range/contact.strength,2);
				me.index = int(256*(contact.getDeviationHeadingFrozen()+60)/120);
				if (me.index<=255 and me.index>= 0) {
					me.values[me.index] += me.distPixels;
					if (me.index+1<=255)
						me.values[me.index+1] += me.distPixels*0.5;
					if (me.index+2<=255)
						me.values[me.index+2] += me.distPixels*0.25;
					if (me.index-1>=0)
						me.values[me.index-1] += me.distPixels*0.5;
					if (me.index-2>=0)
						me.values[me.index-2] += me.distPixels*0.25;
				}
			}
		}
		for (var i = 0;i<256;i+=1) {
			me.line[i].setTranslation(i,-clamp(me.values[i],0,256));
		}
		settimer(func me.loop(), exampleRadar.loopSpeed);
	},
};

ExampleRadar = {
# test radar
	new: func () {
		var vr = ActiveDiscRadar.new();
		append(vr.parents, ExampleRadar);
		vr.discSpeed_dps  = 120;
		vr.fovRadius_deg  = 3.6;
		vr.calcLoop();
		vr.calcBars();
		vr.pattern        = [-58,58,[1,2,3,4,5,6]];#6/8 bars
		vr.forDist_m      = 15000;#range setting
		vr.forRadius_deg  = 61.5;
		vr.posE           = vr.bars[vr.pattern[2][vr.patternBar]];
		vr.posH           = vr.pattern[0];
    	return vr;
	},

	rwsHigh: func {
		#test method
		me.pattern        = [-60,60,[4,5,6,7]];#4/8 bars
		me.directionX     = 1;
		me.patternBar     = 0;
		me.posE           = me.bars[me.pattern[2][me.patternBar]];
		me.posH           = me.pattern[0];
		me.scanMode       = RANGE_WHILE_SEARCH;
		me.discSpeed_dps  = 120;
		me.lock = NONE;
		me.locks = [];
		me.calcLoop();
		me.follow = [];
	},

	rws120: func {
		#test method
		me.pattern        = [-60,60,[1,2,3,4,5,6]];#6/8 bars
		me.directionX     = 1;
		me.patternBar     = 0;
		me.posE           = me.bars[me.pattern[2][me.patternBar]];
		me.posH           = me.pattern[0];
		me.scanMode       = RANGE_WHILE_SEARCH;
		me.discSpeed_dps  = 120;
		me.lock = NONE;
		me.locks = [];
		me.calcLoop();
		#me.follow = [];
	},

	sam: func {
		#test method
		if (size(me.follow)>0 and me.lock != HARD) {
			# toggle SAM off
			me.follow = [];
		} elsif(me.lock == HARD) {
			if (size(me.locks) > 0) {
				me.follow = [me.locks[0]];
				if(me.scanMode == TRACK_WHILE_SCAN) {
					me.lock = SOFT;
				} else {
					me.lock = NONE;
					me.locks = [];
				}				
			}
		} elsif(me.scanMode == RANGE_WHILE_SEARCH) {
			if (size(me.vector_aicontacts_bleps) > 0) {
				me.lock = NONE;
				me.locks = [];
				me.follow = [me.vector_aicontacts_bleps[0]];
			}
		} elsif(me.scanMode == TRACK_WHILE_SCAN) {
			if (size(me.locks) > 0) {
				me.lock = SOFT;
				me.follow = [me.locks[0]];
			}
		}		 
	},

	next: func {
		if (size(me.follow) == 1 and size(me.locks) > 0 and me.lock != HARD) {
			me.index = me.vectorIndex(me.locks, me.follow[0]);
			if (me.index == -1) {
				me.follow = [me.locks[0]];
			} else {
				if (me.index+1 > size(me.locks)-1) {
					me.follow = [];
				} else {
					me.follow = [me.locks[me.index+1]];
				}
			}
		} elsif (size(me.follow) == 1 and size(me.vector_aicontacts_bleps) > 0) {
			me.index = me.vectorIndex(me.vector_aicontacts_bleps, me.follow[0]);
			if (me.index == -1) {
				me.follow = [me.vector_aicontacts_bleps[0]];
			} else {
				if (me.index+1 > size(me.vector_aicontacts_bleps)-1) {
					me.follow = [];
				} else {
					me.follow = [me.vector_aicontacts_bleps[me.index+1]];
				}
			}
		}
	},

	tws15: func {
		#test method
		me.pattern        = [-7.5,7.5,[1,2,3,4,5,6]];#6/8 bars
		me.directionX     = 1;
		me.patternBar     = 0;
		me.posE           = me.bars[me.pattern[2][me.patternBar]];
		me.posH           = me.pattern[0];
		me.scanMode       = TRACK_WHILE_SCAN;
		me.discSpeed_dps  = 60;
		me.calcLoop();
		me.lock = NONE;
		#me.follow = [];
	},

	tws30: func {
		#test method
		me.pattern        = [-15,15,[2,3,4,5]];#4/8 bars
		me.directionX     = 1;
		me.patternBar     = 0;
		me.posE           = me.bars[me.pattern[2][me.patternBar]];
		me.posH           = me.pattern[0];
		me.scanMode       = TRACK_WHILE_SCAN;
		me.discSpeed_dps  = 60;
		me.calcLoop();
		me.lock = NONE;
		#me.follow = [];
	},

	tws60: func {
		#test method
		me.pattern        = [-30,30,[3,4]];#2/8 bars
		me.directionX     = 1;
		me.patternBar     = 0;
		me.posE           = me.bars[me.pattern[2][me.patternBar]];
		me.posH           = me.pattern[0];
		me.scanMode       = TRACK_WHILE_SCAN;
		me.discSpeed_dps  = 60;
		me.calcLoop();
		me.lock = NONE;
		#me.follow = [];
	},

	b2: func {
		me.pattern[2] = [3,4];
	},

	b4: func {
		me.pattern[2] = [2,3,4,5];
	},

	b6: func {
		me.pattern[2] = [1,2,3,4,5,6];
	},

	b8: func {
		me.pattern[2] = [0,1,2,3,4,5,6,7];
	},

	a2: func {
		me.pattern[0] = -15;
		me.pattern[1] =  15;
	},

	a3: func {
		me.pattern[0] = -30;
		me.pattern[1] =  30;
	},

	a4: func {
		me.pattern[0] = -60;
		me.pattern[1] =  60;
	},

	a1: func {
		me.pattern[0] = -7.5;
		me.pattern[1] =  7.5;
	},

	left: func {
		#test method
		var zero = me.pattern[0]-15;
		if (zero >= -me.forRadius_deg) {
			me.pattern[0] = zero;
			me.pattern[1] = me.pattern[1]-15;
		}
	},

	right: func {
		#test method
		var one = me.pattern[1]+15;
		if (one <= me.forRadius_deg) {
			me.pattern[1] = one;
			me.pattern[0] = me.pattern[0]+15;
		}
	},

	up: func {
		#test method
		me.barOffset += 1;
		if (me.barOffset > 4) {
			me.barOffset = 4;
		}
	},

	down: func {
		#test method
		me.barOffset -= 1;
		if (me.barOffset < -4) {
			me.barOffset = -4;
		}
	},

	level: func {
		#test method
		me.barOffset = 0;
	},

	lockRandom: func {
		#test method

		# hard lock
		if (size(me.follow)>0) {
			# chose same lock as being followed with SAM
			if (me.follow[0].getRangeDirect() < max_lock_range*NM2M) {
				me.locks = [me.follow[0]];
				me.lock = HARD;
				me.vector_aicontacts_for = [me.follow[0]];
			}
		} elsif (size(me.vector_aicontacts_bleps)>0) {
			# random chosen lock in range
			foreach (lck ; me.vector_aicontacts_bleps) {
				if (lck.getRangeDirect() < max_lock_range*NM2M) {
					me.locks = [me.vector_aicontacts_bleps[0]];
					me.follow = [me.vector_aicontacts_bleps[0]];
					me.lock = HARD;
					me.vector_aicontacts_for = [me.vector_aicontacts_bleps[0]];
					break;
				}
			}
		}
	},
};





#
# I made this fire-control shell, to get me thinking about way to design such a thing plus pylons.
#

var pylonWsets = {
	a: {id: "2 x AIM-9", content: ["AIM-9","AIM-9"], launcherDragArea: 0.25, launcherMass: 20, launcherJettisonable: 0},
	b: {id: "2 x AIM-120", content: ["AIM-120","AIM-120"], launcherDragArea: 0.25, launcherMass: 20, launcherJettisonable: 0},
	c: {id: "1 x AIM-7", content: ["AIM-7"], launcherDragArea: 0.25, launcherMass: 20, launcherJettisonable: 0},
	d: {id: "1 x GBU-82", content: ["GBU-82"], launcherDragArea: 0.25, launcherMass: 20, launcherJettisonable: 0},
};

var loadAirSuperiority  = [500, "a","b"];# load 500 round into cannon, set 'a' onto left wing pylon, and set 'b' onto right wing pylon.

FireControl = {
# select pylon(s)
# propagate trigger/jettison commands to pylons
# assign targets to arms hanging on pylons
# load entire full sets onto pylons (like in F15)
# no loop.
#
# Attributes:
#   pylon list
#   pylon fire order
};

myFireControl = {

	new: func {
		var fc = {parents: [myFireControl, FireControl]};
		# link to the radar
		fc.activeRadar    = exampleRadar;
		# number of total stations
		fc.stationCount     = 3;
		# the pylon instances
		fc.vector_pylons  = [SubModelStation.new(0, 500), Pylon.new(1,"Left wing", pylonWsets), Pylon.new(2,"Right wing", pylonWsets)];
		# property for trigger
		fc.prop_trigger   = globals.getNode("controls/armament/trigger");
		# when trigger is pulled, fire command is sent to these armaments
		fc.triggerArms    = [[1,0]];#first arm on first pylon
		# current selected armaments. Can send radar contact info to these arms.
		fc.selectedArms   = [[1,0]];
		# order to select between arms types
		fc.orderArmTypes  = ["AIM-9","AIM-7","AIM-120","GBU-82"];
		# order to fire from pylons
		fc.orderPylons    = [0,1,2];#cannon, left then right

		return fc;
	},

	jettisonAll: func {
		# drops everything from all pylons.
	},

	jettison: func {
		# drops current selected arms
	},

	addTrigger: func {
		# the currently selected arms is added to list arms that will fire when trigger is pulled.
	},

	removeTrigger: func {
		# the currently selected arms is removed from list arms that will fire when trigger is pulled.
	},

	autoTrigger: func (enable) {
		# selected arms is auto set to trigger
	},

	assign: func {
		# assign current selected radar contact to current selected arms
	},

	autoAssign: func (enable) {
		# If ON then all contacts in Field of Regard is propegated to selected Arms. (used for heatseekers when radar is off)
	},

	clear: func {
		# select nothing
	},

	setMasterMode: func (mode) {
		# Set master arm OFF, ON, REDUCED, SIM.
	},

	cycleArm: func {
		# cycle between arms of same type
	},

	cycleType: func {
		# cycle between different types of arms. Will also clear trigger list.
	},

	selectType: func {
		# select specific type explicit. Will also clear trigger list.
	},

	selectArm: func {
		# select specific arm explicit
	},

	getSelectedArms: func {
		# get the missile-code instance of selected arms. Returns vector.
	},

	loadFullSets: func (loadSets) {
		# load a full complement onto aircraft.
	},
};

###Station
#

###SubModelStation:
# inherits from station
# Implements a fixed station.
#  cannon/rockets and methods to give them commands.
#  should be able to hold submodels
#  no loop, but lots of listeners.
#
# Attributes:
#  drag, weight, submodel(s)

###Pylon:
# inherits from station
# Implements a pylon.
#  missiles/bombs/rockets and methods to give them commands.
#  sets jsbsim/yasim point mass and drag. Mass is combined of all missile-code instances + launcher mass. Same with drag.
#  interacts with GUI payload dialog  ("2 x AIM9L", "1 x GBU-82"), auto-adjusts the name when munitions is fired/jettisoned.
#  should be able to hold missile-code arms.
#  no loop, but lots of listeners.
#
# Attributes:
#   missile-code instance(s) [each with a unique id number that corresponds to a 3D position]
#   pylon id number
#   jsb pointmass id number
#   GUI payload id number
#   individiual positions for 3D (from xml)
#   possible sets that can be loaded ("2 x AIM9L", "1 x GBU-82") At loadtime, this can be many, so store in Nasal :(







var window = nil;
var buttonWindow = func {
	# a test gui for radar modes
	window = canvas.Window.new([200,450],"dialog").set('title',"Radar modes");
	var myCanvas = window.createCanvas().set("background", canvas.style.getColor("bg_color"));
	var root = myCanvas.createGroup();
	var myLayout0 = canvas.HBoxLayout.new();
	var myLayout = canvas.VBoxLayout.new();
	var myLayout2 = canvas.VBoxLayout.new();
	myCanvas.setLayout(myLayout0);
	myLayout0.addItem(myLayout);
	myLayout0.addItem(myLayout2);
#	var button0 = canvas.gui.widgets.Button.new(root, canvas.style, {})
#		.setText("RWS high")
#		.setFixedSize(75, 25);
#	button0.listen("clicked", func {
#		exampleRadar.rwsHigh();
#	});
#	myLayout.addItem(button0);
	var button1 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("RWS")
		.setFixedSize(75, 25);
	button1.listen("clicked", func {
		exampleRadar.rws120();
	});
	myLayout.addItem(button1);
	var button2 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("TWS 15")
		.setFixedSize(75, 25);
	button2.listen("clicked", func {
		exampleRadar.tws15();
	});
	myLayout.addItem(button2);
	var button3 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("TWS 30")
		.setFixedSize(75, 25);
	button3.listen("clicked", func {
		exampleRadar.tws30();
	});
	myLayout.addItem(button3);
	var button4 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("TWS 60")
		.setFixedSize(75, 25);
	button4.listen("clicked", func {
		exampleRadar.tws60();
	});
	myLayout.addItem(button4);
	var button5 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Left")
		.setFixedSize(75, 25);
	button5.listen("clicked", func {
		exampleRadar.left();
	});
	myLayout.addItem(button5);
	var button6 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Right")
		.setFixedSize(75, 25);
	button6.listen("clicked", func {
		exampleRadar.right();
	});
	myLayout.addItem(button6);
	var button7 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Range+")
		.setFixedSize(75, 20);
	button7.listen("clicked", func {
		nose.more();
	});
	myLayout.addItem(button7);
	var button8 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Range-")
		.setFixedSize(75, 20);
	button8.listen("clicked", func {
		nose.less();
	});
	myLayout.addItem(button8);
	var button9 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Lock")
		.setFixedSize(75, 25);
	button9.listen("clicked", func {
		exampleRadar.lockRandom();
	});
	myLayout.addItem(button9);
	var button10 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("SAM")
		.setFixedSize(75, 25);
	button10.listen("clicked", func {
		exampleRadar.sam();
	});
	myLayout.addItem(button10);
	var button11 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Next")
		.setFixedSize(75, 25);
	button11.listen("clicked", func {
		exampleRadar.next();
	});
	myLayout.addItem(button11);
	var button12 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Up")
		.setFixedSize(75, 25);
	button12.listen("clicked", func {
		exampleRadar.up();
	});
	myLayout.addItem(button12);
	var button13 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Down")
		.setFixedSize(75, 25);
	button13.listen("clicked", func {
		exampleRadar.down();
	});
	myLayout.addItem(button13);
	var button14 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("Level")
		.setFixedSize(75, 25);
	button14.listen("clicked", func {
		exampleRadar.level();
	});
	myLayout.addItem(button14);

	var button15 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("2 Bars")
		.setFixedSize(75, 25);
	button15.listen("clicked", func {
		exampleRadar.b2();
	});
	myLayout2.addItem(button15);
	var button16 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("4 Bars")
		.setFixedSize(75, 25);
	button16.listen("clicked", func {
		exampleRadar.b4();
	});
	myLayout2.addItem(button16);
	var button17 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("6 Bars")
		.setFixedSize(75, 25);
	button17.listen("clicked", func {
		exampleRadar.b6();
	});
	myLayout2.addItem(button17);
	var button18 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("8 Bars")
		.setFixedSize(75, 25);
	button18.listen("clicked", func {
		exampleRadar.b8();
	});
	myLayout2.addItem(button18);
	var button19 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("A1")
		.setFixedSize(75, 25);
	button19.listen("clicked", func {
		exampleRadar.a1();
	});
	myLayout2.addItem(button19);
	var button20 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("A2")
		.setFixedSize(75, 25);
	button20.listen("clicked", func {
		exampleRadar.a2();
	});
	myLayout2.addItem(button20);
	var button21 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("A3")
		.setFixedSize(75, 25);
	button21.listen("clicked", func {
		exampleRadar.a3();
	});
	myLayout2.addItem(button21);
	var button22 = canvas.gui.widgets.Button.new(root, canvas.style, {})
		.setText("A4")
		.setFixedSize(75, 25);
	button22.listen("clicked", func {
		exampleRadar.a4();
	});
	myLayout2.addItem(button22);
};

AIToNasal.new();
var nose = NoseRadar.new(15000,60,5);
var exampleRadar = ExampleRadar.new();
RadarViewPPI.new();
RadarViewBScope.new();
RadarViewCScope.new();
RadarViewAScope.new();
buttonWindow();