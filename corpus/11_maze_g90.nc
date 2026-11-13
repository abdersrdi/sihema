%
O[your six digit birthdate]  
([your name] MAZE) 
(Startup Process)
T1 M06 	 		(Select tool)
G54 			(Use Work Offset G54)		
G90 G17 		(Safe Startup Line: Absolute Programming and Set the active plane as XY)
G00 X0. Y0.  	(Rapid Movement to 0 X,Yand Z axes in work offset)
G43 H01 Z1.0 	(Use Tool Offset #1)
(END Startup Process)

(GO TO THE STARTING POINT AND DROP THE PEN)
G01 [your xy start position] F12.0		(Go to start position and set Cutting Speed to 12 in/min)
M03 S1000		(Spin the pen for better precision)
Z0.0			(Move the pen to the paper)

(MOVEMENTS TO SOLVE THE MAZE)
[put the G90 XY coordinate pairs here]

(END SEQUENCE)
G00 G53 Z0.0	(Raise the pen) 
M30 			(End Program)
%
