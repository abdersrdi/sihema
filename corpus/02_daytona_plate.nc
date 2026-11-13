%
O00001 (OP 1 Drill plate)
(X0Y0 is middle of plate)

T1 M06 (Spot drill)
G90 G54 G00 (Absolute Programming Position, Work Coordinate # 1, Drill Location 1)
S2000 M03 (Start spindle clockwise and set speed to 2000rpm)
G43 H01 Z0.5 M08 (Tool length compensation, tool length offset - Z height change, Coolant ON)
G81 Z-.135 R.25 F10.0 (Drill canned cycle, z change and add radius, clockwise arc )
X-.75 Y-.75 Z-.1425
X.75
Y.75
X-.75
X-2.2625 Y-2.125
Y2.125
X2.2625
Y-2.125
G00 G90 Z0.1 M09 
G28 G91 Z0 M05

(Drill 17/64)
T2 M06 
G90 G54 G00 X0 Y0 
S3500 M03 
G43 H02 Z0.5 M08 
G83 Z-.359 R.25 Q.35 F20.0 
X-.75 Y-.75 Z-.1425
X.75
Y.75
X-.75
X-2.2625 Y-2.125
Y2.125
X2.2625
Y-2.125
G00 G90 Z0.1 M09 
G28 G91 Z0 M05

(15/16 Drill center hole)
T3 M06
G90 G54 G00 X0 Y0
S3500 M03
G43 H03 Z0.5 M08
G83 Z-.359 R.25 Q.35 F27.0
G80 G00 Z1. M09 
G28 G91 Z0 M05

(Reamer .250)
T4 M06
G90 G54 G00 X0 Y0
S1700 M03
G43 H04 Z0.5 M08
G81 Z-.325 R.25 F20.0
G80 G00 Z1. M09 
G28 G91 Z0 M05


m30 (End program)
%