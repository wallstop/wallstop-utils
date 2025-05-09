FasdUAS 1.101.10   ��   ��    k             l     ��  ��    : 4 Version 7: Rigorous Variable Setting Before Logging     � 	 	 h   V e r s i o n   7 :   R i g o r o u s   V a r i a b l e   S e t t i n g   B e f o r e   L o g g i n g   
  
 l     ��������  ��  ��        l     ��  ��    R L ---------------------------------------------------------------------------     �   �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -      l     ��  ��    #  Handler to write a log entry     �   :   H a n d l e r   t o   w r i t e   a   l o g   e n t r y      l     ��  ��    R L ---------------------------------------------------------------------------     �   �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -      i         I      �� ���� 0 writelogentry writeLogEntry     !   o      ���� 0 appname appName !  "�� " o      ���� 0 
windowname 
windowName��  ��    k     � # #  $ % $ l     �� & '��   & &   Define the path to the log file    ' � ( ( @   D e f i n e   t h e   p a t h   t o   t h e   l o g   f i l e %  ) * ) r      + , + b     	 - . - l     /���� / I    �� 0 1
�� .earsffdralis        afdr 0 m     ��
�� afdrcusr 1 �� 2��
�� 
rtyp 2 m    ��
�� 
ctxt��  ��  ��   . m     3 3 � 4 4 2 m i n i m i z e d _ w i n d o w s _ l o g . t x t , o      ���� 0 logfilepath logFilePath *  5 6 5 l   ��������  ��  ��   6  7 8 7 l   ��������  ��  ��   8  9 : 9 l   �� ; <��   ; ( " Log received values for debugging    < � = = D   L o g   r e c e i v e d   v a l u e s   f o r   d e b u g g i n g :  > ? > I   �� @��
�� .ascrcmnt****      � **** @ b     A B A b     C D C b     E F E b     G H G m     I I � J J B w r i t e L o g E n t r y   r e c e i v e d :   a p p N a m e = ' H o    ���� 0 appname appName F m     K K � L L  ' ,   w i n d o w N a m e = ' D o    ���� 0 
windowname 
windowName B m     M M � N N  '��   ?  O P O l   ��������  ��  ��   P  Q R Q l   �� S T��   S = 7 Ensure parameters are not empty before writing to file    T � U U n   E n s u r e   p a r a m e t e r s   a r e   n o t   e m p t y   b e f o r e   w r i t i n g   t o   f i l e R  V W V Z    4 X Y���� X G    % Z [ Z =    \ ] \ o    ���� 0 appname appName ] m    ��
�� 
msng [ =    # ^ _ ^ o     !���� 0 appname appName _ m   ! " ` ` � a a   Y k   ( 0 b b  c d c I  ( -�� e��
�� .ascrcmnt****      � **** e m   ( ) f f � g g v L o g g i n g   E r r o r :   a p p N a m e   i s   m i s s i n g   o r   e m p t y .   S k i p p i n g   w r i t e .��   d  h�� h L   . 0����  ��  ��  ��   W  i j i Z   5 O k l���� k G   5 @ m n m =  5 8 o p o o   5 6���� 0 
windowname 
windowName p m   6 7��
�� 
msng n =  ; > q r q o   ; <���� 0 
windowname 
windowName r m   < = s s � t t   l k   C K u u  v w v I  C H�� x��
�� .ascrcmnt****      � **** x m   C D y y � z z | L o g g i n g   E r r o r :   w i n d o w N a m e   i s   m i s s i n g   o r   e m p t y .   S k i p p i n g   w r i t e .��   w  { | { l  I I�� } ~��   } ? 9 Optionally try to log with a placeholder? For now, skip.    ~ �   r   O p t i o n a l l y   t r y   t o   l o g   w i t h   a   p l a c e h o l d e r ?   F o r   n o w ,   s k i p . |  � � � l  I I�� � ���   � 8 2 set windowName to "(Unknown or Untitled Window)"     � � � � d   s e t   w i n d o w N a m e   t o   " ( U n k n o w n   o r   U n t i t l e d   W i n d o w ) "   �  ��� � L   I K����  ��  ��  ��   j  � � � l  P P��������  ��  ��   �  � � � r   P k � � � b   P i � � � b   P e � � � b   P c � � � b   P _ � � � b   P ] � � � l  P Y ����� � c   P Y � � � l  P U ����� � I  P U������
�� .misccurdldt    ��� null��  ��  ��  ��   � m   U X��
�� 
TEXT��  ��   � m   Y \ � � � � �    |   � o   ] ^���� 0 appname appName � m   _ b � � � � �    |   � o   c d���� 0 
windowname 
windowName � 1   e h��
�� 
lnfd � o      ���� 0 logentry logEntry �  � � � l  l l��������  ��  ��   �  ��� � Q   l � � � � � k   o � � �  � � � r   o  � � � I  o }�� � �
�� .rdwropenshor       file � 4   o u�� �
�� 
file � o   s t���� 0 logfilepath logFilePath � �� ���
�� 
perm � m   x y��
�� boovtrue��   � o      ����  0 filedescriptor fileDescriptor �  � � � I  � ��� � �
�� .rdwrwritnull���     **** � o   � ����� 0 logentry logEntry � �� � �
�� 
refn � o   � �����  0 filedescriptor fileDescriptor � �� ���
�� 
wrat � m   � ���
�� rdwreof ��   �  � � � I  � ��� ���
�� .rdwrclosnull���     **** � o   � �����  0 filedescriptor fileDescriptor��   �  ��� � I  � ��� ���
�� .ascrcmnt****      � **** � b   � � � � � b   � � � � � b   � � � � � m   � � � � � � �   L o g g e d   t o   f i l e :   � o   � ����� 0 appname appName � m   � � � � � � �    |   � o   � ����� 0 
windowname 
windowName��  ��   � R      �� � �
�� .ascrerr ****      � **** � o      ���� 0 errmsg errMsg � �� ���
�� 
errn � o      ���� 0 errnum errNum��   � k   � � � �  � � � I  � ��� ���
�� .ascrcmnt****      � **** � b   � � � � � m   � � � � � � � X L o g g i n g   E r r o r :   F a i l e d   t o   w r i t e   t o   l o g   f i l e :   � o   � ����� 0 errmsg errMsg��   �  ��� � Q   � � � ��� � I  � ��� ���
�� .rdwrclosnull���     **** � 4   � ��� �
�� 
file � o   � ����� 0 logfilepath logFilePath��   � R      ������
�� .ascrerr ****      � ****��  ��  ��  ��  ��     � � � l     ��������  ��  ��   �  � � � l     ��������  ��  ��   �  � � � l     �� � ���   � R L ---------------------------------------------------------------------------    � � � � �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - �  � � � l     �� � ���   �   Main Script Logic    � � � � $   M a i n   S c r i p t   L o g i c �  � � � l     �� � ���   � R L ---------------------------------------------------------------------------    � � � � �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - �  � � � l     ����� � r      � � � m     ��
�� boovfals � o      ���� 0 didminimize didMinimize��  ��   �  � � � l    � � � � r     � � � m    �
� 
msng � o      �~�~ 0 frontappname frontAppName � "  Use missing value initially    � � � � 8   U s e   m i s s i n g   v a l u e   i n i t i a l l y �  � � � l    ��}�| � r     � � � m    	�{
�{ 
msng � o      �z�z "0 frontappprocess frontAppProcess�}  �|   �  � � � l    � � � � r     � � � m    �y
�y 
msng � o      �x�x *0 capturedwindowtitle capturedWindowTitle �   Use missing value    � � � � $   U s e   m i s s i n g   v a l u e �    l     �w�v�u�w  �v  �u   �t l  ��s�r Q   � k   � 	 l   �q
�q  
 K E Step 1: Identify the frontmost (active) application PROCESS and NAME    � �   S t e p   1 :   I d e n t i f y   t h e   f r o n t m o s t   ( a c t i v e )   a p p l i c a t i o n   P R O C E S S   a n d   N A M E	  I   �p�o
�p .ascrcmnt****      � **** m     � X S t e p   1 :   I d e n t i f y i n g   f r o n t m o s t   a p p l i c a t i o n . . .�o    O     Q    ~ k     \  r     / 6    - 4    $�n 
�n 
pcap  m   " #�m�m  =  % ,!"! 1   & (�l
�l 
pisf" m   ) +�k
�k boovtrue o      �j�j "0 frontappprocess frontAppProcess #$# r   0 5%&% n   0 3'(' 1   1 3�i
�i 
pnam( o   0 1�h�h "0 frontappprocess frontAppProcess& o      �g�g 0 frontappname frontAppName$ )*) Z   6 L+,�f�e+ G   6 A-.- =  6 9/0/ o   6 7�d�d 0 frontappname frontAppName0 m   7 8�c
�c 
msng. =  < ?121 o   < =�b�b 0 frontappname frontAppName2 m   = >33 �44  , R   D H�a5�`
�a .ascrerr ****      � ****5 m   F G66 �77 l F a i l e d   t o   g e t   n a m e   f r o m   f r o n t m o s t   a p p l i c a t i o n   p r o c e s s .�`  �f  �e  * 8�_8 I  M \�^9�]
�^ .ascrcmnt****      � ****9 b   M X:;: b   M V<=< b   M R>?> m   M N@@ �AA 2 F o u n d   f r o n t   A p p   P r o c e s s :  ? l  N QB�\�[B n   N QCDC 1   O Q�Z
�Z 
pnamD o   N O�Y�Y "0 frontappprocess frontAppProcess�\  �[  = m   R UEE �FF  ,   A p p   N a m e :  ; o   V W�X�X 0 frontappname frontAppName�]  �_   R      �WG�V
�W .ascrerr ****      � ****G o      �U�U 0 errmsg errMsg�V   k   d ~HH IJI I  d m�TK�S
�T .ascrcmnt****      � ****K b   d iLML m   d gNN �OO r E r r o r   i d e n t i f y i n g   f r o n t m o s t   a p p l i c a t i o n   p r o c e s s   o r   n a m e :  M o   g h�R�R 0 errmsg errMsg�S  J PQP I  n {�QRS
�Q .sysonotfnull��� ��� TEXTR m   n qTT �UU Z C o u l d   n o t   i d e n t i f y   t h e   f r o n t m o s t   a p p l i c a t i o n .S �PV�O
�P 
apprV m   t wWW �XX  M i n i m i z e   E r r o r�O  Q Y�NY L   | ~�M�M  �N   m    ZZ�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��   [\[ l  � ��L�K�J�L  �K  �J  \ ]^] l  � ��I_`�I  _ 7 1 Attempt 1: System Events - Click Minimize Button   ` �aa b   A t t e m p t   1 :   S y s t e m   E v e n t s   -   C l i c k   M i n i m i z e   B u t t o n^ bcb Z   �?de�H�Gd H   � �ff o   � ��F�F 0 didminimize didMinimizee k   �;gg hih I  � ��Ej�D
�E .ascrcmnt****      � ****j m   � �kk �ll B A t t e m p t i n g   M e t h o d   1 :   C l i c k   B u t t o n�D  i mnm l  � �opqo r   � �rsr m   � ��C
�C 
msngs o      �B�B *0 capturedwindowtitle capturedWindowTitlep   Reset for this attempt   q �tt .   R e s e t   f o r   t h i s   a t t e m p tn u�Au Q   �;vwxv l  �*yz{y O   �*|}| l  �)~�~ O   �)��� k   �(�� ��� Z  � ����@�?� H   � ��� l  � ���>�=� I  � ��<��;
�< .coredoexnull���     ****� 4  � ��:�
�: 
cwin� m   � ��9�9 �;  �>  �=  � R   � ��8��7
�8 .ascrerr ****      � ****� m   � ��� ��� P F r o n t   w i n d o w   d o e s   n o t   e x i s t   f o r   p r o c e s s .�7  �@  �?  � ��� l  � ��6�5�4�6  �5  �4  � ��� r   � ���� 4  � ��3�
�3 
cwin� m   � ��2�2 � o      �1�1 0 frontwin frontWin� ��� l  � ����� r   � ���� n   � ���� 1   � ��0
�0 
pnam� o   � ��/�/ 0 frontwin frontWin� o      �.�. *0 capturedwindowtitle capturedWindowTitle�   CAPTURE TITLE   � ���    C A P T U R E   T I T L E� ��� Z  � ����-�,� G   � ���� =  � ���� o   � ��+�+ *0 capturedwindowtitle capturedWindowTitle� m   � ��*
�* 
msng� =  � ���� o   � ��)�) *0 capturedwindowtitle capturedWindowTitle� m   � ��� ���  � R   � ��(��'
�( .ascrerr ****      � ****� m   � ��� ��� V F a i l e d   t o   g e t   w i n d o w   t i t l e   b e f o r e   c l i c k i n g .�'  �-  �,  � ��� l  � ��&�%�$�&  �%  �$  � ��� Z  ����#�"� H   � ��� l  � ���!� � I  � ����
� .coredoexnull���     ****� n   � ���� 4   � ���
� 
butT� m   � ��� ���  M i n i m i z e� o   � ��� 0 frontwin frontWin�  �!  �   � R   � ����
� .ascrerr ****      � ****� b   � ���� m   � ��� ��� V M i n i m i z e   b u t t o n   d o e s   n o t   e x i s t   f o r   w i n d o w :  � o   � ��� *0 capturedwindowtitle capturedWindowTitle�  �#  �"  � ��� l ����  �  �  � ��� I ���
� .prcsclicnull��� ��� uiel� n  ��� 4  ��
� 
butT� m  �� ���  M i n i m i z e� o  �� 0 frontwin frontWin�  � ��� l ����  � ( " If click succeeded without error:   � ��� D   I f   c l i c k   s u c c e e d e d   w i t h o u t   e r r o r :� ��� I ���
� .ascrcmnt****      � ****� b  ��� m  �� ��� N M e t h o d   1 :   C l i c k   s u c c e s s f u l   f o r   w i n d o w :  � o  �� *0 capturedwindowtitle capturedWindowTitle�  � ��� l "���� n "��� I  "���� 0 writelogentry writeLogEntry� ��� o  �� 0 frontappname frontAppName� ��
� o  �	�	 *0 capturedwindowtitle capturedWindowTitle�
  �  �  f  � 1 + LOGGING CALL (with freshly captured title)   � ��� V   L O G G I N G   C A L L   ( w i t h   f r e s h l y   c a p t u r e d   t i t l e )� ��� r  #&��� m  #$�
� boovtrue� o      �� 0 didminimize didMinimize� ��� l ''����  �  �  �  � o   � ��� "0 frontappprocess frontAppProcess   end tell frontAppProcess   � ��� 2   e n d   t e l l   f r o n t A p p P r o c e s s} m   � ����                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  z   end tell System Events   { ��� .   e n d   t e l l   S y s t e m   E v e n t sw R      ���
� .ascrerr ****      � ****� o      � �  0 errmsg errMsg� �����
�� 
errn� o      ���� 0 errnum errNum��  x I 2;�����
�� .ascrcmnt****      � ****� b  27��� m  25�� ��� " M e t h o d   1   F a i l e d :  � o  56���� 0 errmsg errMsg��  �A  �H  �G  c ��� l @@��������  ��  ��  � ��� l @@������  � 7 1 Attempt 2: System Events - AXMinimized Attribute   � ��� b   A t t e m p t   2 :   S y s t e m   E v e n t s   -   A X M i n i m i z e d   A t t r i b u t e� ��� Z  @�������� H  @B�� o  @A���� 0 didminimize didMinimize� k  E�    I EL����
�� .ascrcmnt****      � **** m  EH � T A t t e m p t i n g   M e t h o d   2 :   A X M i n i m i z e d   A t t r i b u t e��    l MP	
 r  MP m  MN��
�� 
msng o      ���� *0 capturedwindowtitle capturedWindowTitle	   Reset for this attempt   
 � .   R e s e t   f o r   t h i s   a t t e m p t �� Q  Q� l T� O  T� l X� O  X� k  \�  Z \t ���� H  \g!! l \f"����" I \f��#��
�� .coredoexnull���     ****# 4 \b��$
�� 
cwin$ m  `a���� ��  ��  ��    R  jp��%��
�� .ascrerr ****      � ****% m  lo&& �'' P F r o n t   w i n d o w   d o e s   n o t   e x i s t   f o r   p r o c e s s .��  ��  ��   ()( l uu��������  ��  ��  ) *+* r  u,-, 4 u{��.
�� 
cwin. m  yz���� - o      ���� 0 frontwin frontWin+ /0/ l ��1231 r  ��454 n  ��676 1  ����
�� 
pnam7 o  ������ 0 frontwin frontWin5 o      ���� *0 capturedwindowtitle capturedWindowTitle2   CAPTURE TITLE   3 �88    C A P T U R E   T I T L E0 9:9 Z ��;<����; G  ��=>= = ��?@? o  ������ *0 capturedwindowtitle capturedWindowTitle@ m  ����
�� 
msng> = ��ABA o  ������ *0 capturedwindowtitle capturedWindowTitleB m  ��CC �DD  < R  ����E��
�� .ascrerr ****      � ****E m  ��FF �GG l F a i l e d   t o   g e t   w i n d o w   t i t l e   b e f o r e   s e t t i n g   A X M i n i m i z e d .��  ��  ��  : HIH l ����������  ��  ��  I JKJ r  ��LML m  ����
�� boovtrueM n      NON 1  ����
�� 
valLO n  ��PQP 4  ����R
�� 
attrR m  ��SS �TT  A X M i n i m i z e dQ o  ������ 0 frontwin frontWinK UVU l ����WX��  W 4 . If setting attribute succeeded without error:   X �YY \   I f   s e t t i n g   a t t r i b u t e   s u c c e e d e d   w i t h o u t   e r r o r :V Z[Z I ����\��
�� .ascrcmnt****      � ****\ b  ��]^] m  ��__ �`` b M e t h o d   2 :   S e t   A X M i n i m i z e d   s u c c e s s f u l   f o r   w i n d o w :  ^ o  ������ *0 capturedwindowtitle capturedWindowTitle��  [ aba l ��cdec n ��fgf I  ����h���� 0 writelogentry writeLogEntryh iji o  ������ 0 frontappname frontAppNamej k��k o  ������ *0 capturedwindowtitle capturedWindowTitle��  ��  g  f  ��d 1 + LOGGING CALL (with freshly captured title)   e �ll V   L O G G I N G   C A L L   ( w i t h   f r e s h l y   c a p t u r e d   t i t l e )b mnm r  ��opo m  ����
�� boovtruep o      ���� 0 didminimize didMinimizen q��q l ����������  ��  ��  ��   o  XY���� "0 frontappprocess frontAppProcess   end tell frontAppProcess    �rr 2   e n d   t e l l   f r o n t A p p P r o c e s s m  TUss�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��     end tell System Events    �tt .   e n d   t e l l   S y s t e m   E v e n t s R      ��uv
�� .ascrerr ****      � ****u o      ���� 0 errmsg errMsgv ��w��
�� 
errnw o      ���� 0 errnum errNum��   I ����x��
�� .ascrcmnt****      � ****x b  ��yzy m  ��{{ �|| " M e t h o d   2   F a i l e d :  z o  ������ 0 errmsg errMsg��  ��  ��  ��  � }~} l ����������  ��  ��  ~ � l ��������  � F @ Attempt 3: Direct Application Scripting - Miniaturized Property   � ��� �   A t t e m p t   3 :   D i r e c t   A p p l i c a t i o n   S c r i p t i n g   -   M i n i a t u r i z e d   P r o p e r t y� ��� Z  ��������� H  ���� o  ������ 0 didminimize didMinimize� k  ���� ��� I �������
�� .ascrcmnt****      � ****� b  ����� m  ���� ��� h A t t e m p t i n g   M e t h o d   3 :   M i n i a t u r i z e d   P r o p e r t y   f o r   a p p :  � o  ������ 0 frontappname frontAppName��  � ��� l ������ r  ����� m  ����
�� 
msng� o      ���� *0 capturedwindowtitle capturedWindowTitle�   Reset for this attempt   � ��� .   R e s e t   f o r   t h i s   a t t e m p t� ���� Q  ������ k  ���� ��� l ��������  � C = Check if the target application is running before telling it   � ��� z   C h e c k   i f   t h e   t a r g e t   a p p l i c a t i o n   i s   r u n n i n g   b e f o r e   t e l l i n g   i t� ��� Z �������� H  ��� l ������� = ���� n  ���� 1  ���
�� 
prun� 4  �����
�� 
capp� o  ������ 0 frontappname frontAppName� m  ��
�� boovtrue��  ��  � R  	�����
�� .ascrerr ****      � ****� b  ��� o  ���� 0 frontappname frontAppName� m  �� ���     i s   n o t   r u n n i n g .��  ��  ��  � ��� l ��������  ��  ��  � ��� l ����� O  ���� k  ��� ��� Z 9������� = *��� l (������ I (�����
�� .corecnte****       ****� 2 $��
�� 
cwin��  ��  ��  � m  ()����  � R  -5�����
�� .ascrerr ****      � ****� b  /4��� o  /0���� 0 frontappname frontAppName� m  03�� ��� 6   r e p o r t s   i t   h a s   n o   w i n d o w s .��  ��  ��  � ��� l ::��������  ��  ��  � ��� Q  :����� k  =��� ��� r  =G��� 4 =C���
�� 
cwin� m  AB���� � o      ���� 0 frontwin frontWin� ��� l HO���� r  HO��� n  HM��� 1  KM��
�� 
pnam� o  HK���� 0 frontwin frontWin� o      ���� *0 capturedwindowtitle capturedWindowTitle�   CAPTURE TITLE   � ���    C A P T U R E   T I T L E� ��� Z Pj������� G  P]��� = PS��� o  PQ���� *0 capturedwindowtitle capturedWindowTitle� m  QR��
�� 
msng� = V[��� o  VW���� *0 capturedwindowtitle capturedWindowTitle� m  WZ�� ���  � R  `f���~
� .ascrerr ****      � ****� m  be�� ��� ` F a i l e d   t o   g e t   w i n d o w   t i t l e   v i a   d i r e c t   s c r i p t i n g .�~  ��  ��  � ��� l kk�}�|�{�}  �|  �{  � ��� r  kt��� m  kl�z
�z boovtrue� n      ��� 1  os�y
�y 
pmnd� o  lo�x�x 0 frontwin frontWin� ��� l uu�w���w  � 7 1 If setting miniaturized succeeded without error:   � ��� b   I f   s e t t i n g   m i n i a t u r i z e d   s u c c e e d e d   w i t h o u t   e r r o r :� ��� I u~�v��u
�v .ascrcmnt****      � ****� b  uz   m  ux � d M e t h o d   3 :   S e t   m i n i a t u r i z e d   s u c c e s s f u l   f o r   w i n d o w :   o  xy�t�t *0 capturedwindowtitle capturedWindowTitle�u  �  l � n �	
	 I  ���s�r�s 0 writelogentry writeLogEntry  o  ���q�q 0 frontappname frontAppName �p o  ���o�o *0 capturedwindowtitle capturedWindowTitle�p  �r  
  f  � 1 + LOGGING CALL (with freshly captured title)    � V   L O G G I N G   C A L L   ( w i t h   f r e s h l y   c a p t u r e d   t i t l e )  r  �� m  ���n
�n boovtrue o      �m�m 0 didminimize didMinimize �l l ���k�j�i�k  �j  �i  �l  � R      �h
�h .ascrerr ****      � **** o      �g�g 0 errmsginner errMsgInner �f�e
�f 
errn o      �d�d 0 errnuminner errNumInner�e  � l �� R  ���c�b
�c .ascrerr ****      � **** b  �� m  �� � ^ E r r o r   a c c e s s i n g / s e t t i n g   f r o n t   w i n d o w   d i r e c t l y :   o  ���a�a 0 errmsginner errMsgInner�b     Re-throw inner error    �   *   R e - t h r o w   i n n e r   e r r o r� !�`! l ���_�^�]�_  �^  �]  �`  � 4  �\"
�\ 
capp" o  �[�[ 0 frontappname frontAppName� ( " end tell application frontAppName   � �## D   e n d   t e l l   a p p l i c a t i o n   f r o n t A p p N a m e� $�Z$ l ���Y�X�W�Y  �X  �W  �Z  � R      �V%&
�V .ascrerr ****      � ****% o      �U�U 0 errmsg errMsg& �T'�S
�T 
errn' o      �R�R 0 errnum errNum�S  � k  ��(( )*) l ���Q+,�Q  + a [ This catches errors like app not running, no windows, or not scriptable for 'miniaturized'   , �-- �   T h i s   c a t c h e s   e r r o r s   l i k e   a p p   n o t   r u n n i n g ,   n o   w i n d o w s ,   o r   n o t   s c r i p t a b l e   f o r   ' m i n i a t u r i z e d '* .�P. I ���O/�N
�O .ascrcmnt****      � ****/ b  ��010 m  ��22 �33 " M e t h o d   3   F a i l e d :  1 o  ���M�M 0 errmsg errMsg�N  �P  ��  ��  ��  � 454 l ���L�K�J�L  �K  �J  5 676 l ���I89�I  8 #  Final Check and Focus Switch   9 �:: :   F i n a l   C h e c k   a n d   F o c u s   S w i t c h7 ;�H; l ��<=>< Z  ��?@�GA? H  ��BB o  ���F�F 0 didminimize didMinimize@ k  ��CC DED I ���EF�D
�E .ascrcmnt****      � ****F m  ��GG �HH @ A l l   m i n i m i z a t i o n   m e t h o d s   f a i l e d .�D  E I�CI I ���BJK
�B .sysonotfnull��� ��� TEXTJ m  ��LL �MM X F a i l e d   t o   m i n i m i z e   w i n d o w   u s i n g   a l l   m e t h o d s .K �AN�@
�A 
apprN m  ��OO �PP  M i n i m i z e   F a i l e d�@  �C  �G  A k  ��QQ RSR I ���?T�>
�? .ascrcmnt****      � ****T b  ��UVU b  ��WXW m  ��YY �ZZ > W i n d o w   m i n i m i z e d   s u c c e s s f u l l y   (X o  ���=�= *0 capturedwindowtitle capturedWindowTitleV m  ��[[ �\\ < ) .   P r o c e e d i n g   t o   s w i t c h   f o c u s .�>  S ]^] l ���<�;�:�<  �;  �:  ^ _`_ l ���9ab�9  a   Step 4: Switch focus    b �cc ,   S t e p   4 :   S w i t c h   f o c u s  ` ded r  �fgf J  ��hh iji m  ��kk �ll 
 R i d e rj mnm m  ��oo �pp  S a f a r in qrq m  ��ss �tt  T e r m i n a lr uvu m  ��ww �xx  D i s c o r dv yzy m  ��{{ �||  M a i lz }~} m  �� ���  S p o t i f y~ ��� m  ���� ���  M s t y� ��8� m  ���� ���  O b s i d i a n�8  g o      �7�7 0 preferredapps preferredAppse ��� l ���� r  ��� m  �6
�6 boovfals� o      �5�5 0 appfound appFound� 8 2 Flag to track if we successfully activated an app   � ��� d   F l a g   t o   t r a c k   i f   w e   s u c c e s s f u l l y   a c t i v a t e d   a n   a p p� ��� l 		�4�3�2�4  �3  �2  � ��� I 	�1��0
�1 .ascrcmnt****      � ****� m  	�� ��� � S t a r t i n g   f o c u s   s w i t c h :   L o o k i n g   f o r   p r e f e r r e d   a p p s   w i t h   v i s i b l e ,   n o n - m i n i m i z e d   w i n d o w s . . .�0  � ��� l �/���/  � + % Loop 1: Check Preferred Applications   � ��� J   L o o p   1 :   C h e c k   P r e f e r r e d   A p p l i c a t i o n s� ��� X  ��.�� Z  '���-�,� > '*��� o  '(�+�+ 0 appname appName� o  ()�*�* 0 frontappname frontAppName� k  -�� ��� l -2���� r  -2��� m  -.�)
�) boovfals� o      �(�( 0 canactivate canActivate� ' ! Reset flag for this specific app   � ��� B   R e s e t   f l a g   f o r   t h i s   s p e c i f i c   a p p� ��'� Q  3���&� k  6�� ��� l 6����� O  6���� k  :��� ��� l ::�%���%  � ; 5 Check if the process exists and is visible on screen   � ��� j   C h e c k   i f   t h e   p r o c e s s   e x i s t s   a n d   i s   v i s i b l e   o n   s c r e e n� ��$� l :����� Z  :����#�"� I :M�!�� 
�! .coredoexnull���     ****� l :I���� 6:I��� 4  :>��
� 
pcap� o  <=�� 0 appname appName� = ?H��� 1  @D�
� 
pvis� m  EG�
� boovtrue�  �  �   � k  P��� ��� r  PX��� 4  PT��
� 
pcap� o  RS�� 0 appname appName� o      �� 0 
theprocess 
theProcess� ��� l YY����  �  �  � ��� l YY����  � 8 2 Check if the process has any windows at all first   � ��� d   C h e c k   i f   t h e   p r o c e s s   h a s   a n y   w i n d o w s   a t   a l l   f i r s t� ��� l Y����� Z  Y������ I Ye���
� .coredoexnull���     ****� l Ya���� n  Ya��� 4  \a��
� 
cwin� m  _`�
�
 � o  Y\�	�	 0 
theprocess 
theProcess�  �  �  � k  h��� ��� l hh����  �  �  � ��� l hh����  � = 7 *** ALTERNATIVE METHOD: Get all windows, then loop ***   � ��� n   * * *   A L T E R N A T I V E   M E T H O D :   G e t   a l l   w i n d o w s ,   t h e n   l o o p   * * *� ��� r  hs��� n  ho��� 2 ko�
� 
cwin� o  hk�� 0 
theprocess 
theProcess� o      �� 0 
allwindows 
allWindows� ��� l t����� X  t����� Q  ������ Z  ����� ��� = ����� n  ��� � 1  ����
�� 
valL  n  �� 4  ����
�� 
attr m  �� �  A X M i n i m i z e d o  ������ 0 awindow aWindow� m  ����
�� boovfals� k  ��  l ��	
	 r  �� m  ����
�� boovtrue o      ���� 0 canactivate canActivate
 #  Found a non-minimized window    � :   F o u n d   a   n o n - m i n i m i z e d   w i n d o w �� l ��  S  �� ) # Stop checking windows for this app    � F   S t o p   c h e c k i n g   w i n d o w s   f o r   t h i s   a p p��  �   ��  � R      ����
�� .ascrerr ****      � **** o      ���� 0 
errmsgloop 
errMsgLoop��  � k  ��  l ������   W Q Log error fetching attribute for a specific window, but continue checking others    � �   L o g   e r r o r   f e t c h i n g   a t t r i b u t e   f o r   a   s p e c i f i c   w i n d o w ,   b u t   c o n t i n u e   c h e c k i n g   o t h e r s �� I ������
�� .ascrcmnt****      � **** b  �� b  ��  b  ��!"! m  ��## �$$ T E r r o r   g e t t i n g   A X M i n i m i z e d   f o r   a   w i n d o w   o f  " o  ������ 0 appname appName  m  ��%% �&&  :   o  ������ 0 
errmsgloop 
errMsgLoop��  ��  � 0 awindow aWindow� o  wz���� 0 
allwindows 
allWindows�   End loop through windows   � �'' 2   E n d   l o o p   t h r o u g h   w i n d o w s� ()( l ����*+��  * %  *** END ALTERNATIVE METHOD ***   + �,, >   * * *   E N D   A L T E R N A T I V E   M E T H O D   * * *) -��- l ����������  ��  ��  ��  �  �  �   End check for any window   � �.. 2   E n d   c h e c k   f o r   a n y   w i n d o w�  �#  �"  � $  End check for visible process   � �// <   E n d   c h e c k   f o r   v i s i b l e   p r o c e s s�$  � m  6700�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  �   End System Events tell   � �11 .   E n d   S y s t e m   E v e n t s   t e l l� 232 l ����������  ��  ��  3 454 l ����67��  6 ? 9 If a suitable window was found, activate the application   7 �88 r   I f   a   s u i t a b l e   w i n d o w   w a s   f o u n d ,   a c t i v a t e   t h e   a p p l i c a t i o n5 9:9 Z  �
;<����; o  ������ 0 canactivate canActivate< k  �== >?> I ����@��
�� .ascrcmnt****      � ****@ b  ��ABA b  ��CDC m  ��EE �FF < F o u n d   s u i t a b l e   p r e f e r r e d   a p p :  D o  ������ 0 appname appNameB m  ��GG �HH  .   A c t i v a t i n g . . .��  ? IJI O ��KLK I ��������
�� .miscactvnull��� ��� null��  ��  L 4  ����M
�� 
cappM o  ������ 0 appname appNameJ NON r  ��PQP m  ����
�� boovtrueQ o      ���� 0 appfound appFoundO RSR I ���T��
�� .ascrcmnt****      � ****T b  � UVU m  ��WW �XX L S u c c e s s f u l l y   a c t i v a t e d   p r e f e r r e d   a p p :  V o  ������ 0 appname appName��  S Y��Y  S  ��  ��  ��  : Z��Z l ��������  ��  ��  ��  � R      ��[��
�� .ascrerr ****      � ****[ o      ���� $0 errmsgswitchpref errMsgSwitchPref��  �&  �'  �-  �,  �. 0 appname appName� o  ���� 0 preferredapps preferredApps� \]\ l ��������  ��  ��  ] ^_^ l ��`a��  ` S M Loop 2: Check Other Running Applications (if no preferred app was activated)   a �bb �   L o o p   2 :   C h e c k   O t h e r   R u n n i n g   A p p l i c a t i o n s   ( i f   n o   p r e f e r r e d   a p p   w a s   a c t i v a t e d )_ cdc l �efge Z  �hi����h H  #jj o  "���� 0 appfound appFoundi k  &kk lml I &-��n��
�� .ascrcmnt****      � ****n m  &)oo �pp � N o   s u i t a b l e   p r e f e r r e d   a p p   f o u n d .   S e a r c h i n g   a l l   o t h e r   v i s i b l e   a p p s . . .��  m qrq O  .vsts Q  2uuvwu r  5]xyx 65Yz{z 2 58��
�� 
pcap{ F  9X|}| F  :M~~ = ;D��� 1  <@��
�� 
pvis� m  AC��
�� boovtrue > EL��� 1  FH��
�� 
pnam� o  IK���� 0 frontappname frontAppName} = NW��� 1  OS��
�� 
bkgo� m  TV��
�� boovfalsy o      ����  0 otherprocesses otherProcessesv R      �����
�� .ascrerr ****      � ****� o      ����  0 errmsgproclist errMsgProcList��  w k  eu�� ��� r  ek��� J  eg����  � o      ����  0 otherprocesses otherProcesses� ���� I lu�����
�� .ascrcmnt****      � ****� b  lq��� m  lo�� ��� ^ E r r o r   g e t t i n g   l i s t   o f   o t h e r   v i s i b l e   p r o c e s s e s :  � o  op����  0 errmsgproclist errMsgProcList��  ��  t m  ./���                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  r ��� l ww��������  ��  ��  � ���� l w���� X  w����� l �z���� k  �z�� ��� r  ����� n  ����� 1  ����
�� 
pnam� o  ������ 0 
theprocess 
theProcess� o      ���� 0 otherappname otherAppName� ��� l ������ r  ����� m  ����
�� boovfals� o      ���� 0 canactivate canActivate�   Reset flag   � ���    R e s e t   f l a g� ���� Q  �z���� k  �a�� ��� l ��������  � C = *** START Tell System Events (for this specific process) ***   � ��� z   * * *   S T A R T   T e l l   S y s t e m   E v e n t s   ( f o r   t h i s   s p e c i f i c   p r o c e s s )   * * *� ��� l ��������  � H B We need to tell SE we are working with the 'theProcess' reference   � ��� �   W e   n e e d   t o   t e l l   S E   w e   a r e   w o r k i n g   w i t h   t h e   ' t h e P r o c e s s '   r e f e r e n c e� ��� O  ���� k  ��� ��� l ��������  � 4 . Check if it has windows first for efficiency.   � ��� \   C h e c k   i f   i t   h a s   w i n d o w s   f i r s t   f o r   e f f i c i e n c y .� ���� l ����� Z  �������� I �������
�� .coredoexnull���     ****� l �������� n  ����� 4  �����
�� 
cwin� m  ������ � o  ������ 0 
theprocess 
theProcess��  ��  ��  � k  ��� ��� l ��������  � &   Get windows (inside SE context)   � ��� @   G e t   w i n d o w s   ( i n s i d e   S E   c o n t e x t )� ��� r  ����� n  ����� 2 ����
�� 
cwin� o  ������ 0 
theprocess 
theProcess� o      ���� 0 
allwindows 
allWindows� ��� l ����������  ��  ��  � ��� l ��������  � / ) Loop through windows (inside SE context)   � ��� R   L o o p   t h r o u g h   w i n d o w s   ( i n s i d e   S E   c o n t e x t )� ���� l ����� X  ������ Q  ����� k  ���� ��� l ��������  � * $ Check attribute (inside SE context)   � ��� H   C h e c k   a t t r i b u t e   ( i n s i d e   S E   c o n t e x t )� ���� Z  ��������� = ����� n  ����� 1  ����
�� 
valL� n  ����� 4  �����
�� 
attr� m  ���� ���  A X M i n i m i z e d� o  ������ 0 awindow aWindow� m  ����
�� boovfals� k  ����    r  �� m  ����
�� boovtrue o      ���� 0 canactivate canActivate ��  S  ����  ��  ��  ��  � R      ����
�� .ascrerr ****      � **** o      ���� 0 errmsgloop2 errMsgLoop2��  � I �����
�� .ascrcmnt****      � **** b  � b  �	
	 b  �� m  �� � T E r r o r   g e t t i n g   A X M i n i m i z e d   f o r   a   w i n d o w   o f   o  ���� 0 otherappname otherAppName
 m  �  �  :   o  �~�~ 0 errmsgloop2 errMsgLoop2��  �� 0 awindow aWindow� o  ���}�} 0 
allwindows 
allWindows�   End window loop   � �     E n d   w i n d o w   l o o p��  ��  ��  �   End check for windows   � � ,   E n d   c h e c k   f o r   w i n d o w s��  � m  ���                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  �  l �|�|   %  *** END Tell System Events ***    � >   * * *   E N D   T e l l   S y s t e m   E v e n t s   * * *  l �{�z�y�{  �z  �y    l �x�x   : 4 Activation logic (outside SE block, using the flag)    � h   A c t i v a t i o n   l o g i c   ( o u t s i d e   S E   b l o c k ,   u s i n g   t h e   f l a g )  !  Z  _"#�w$" o  �v�v 0 canactivate canActivate# k  M%% &'& I '�u(�t
�u .ascrcmnt****      � ****( b  #)*) b  +,+ m  -- �.. 4 F o u n d   s u i t a b l e   o t h e r   a p p :  , o  �s�s 0 otherappname otherAppName* m  "// �00  .   A c t i v a t i n g . . .�t  ' 121 O (9343 I 38�r�q�p
�r .miscactvnull��� ��� null�q  �p  4 4  (0�o5
�o 
capp5 o  ,/�n�n 0 otherappname otherAppName2 676 r  :?898 m  :;�m
�m boovtrue9 o      �l�l 0 appfound appFound7 :;: I @K�k<�j
�k .ascrcmnt****      � ****< b  @G=>= m  @C?? �@@ D S u c c e s s f u l l y   a c t i v a t e d   o t h e r   a p p :  > o  CF�i�i 0 otherappname otherAppName�j  ; A�hA  S  LM�h  �w  $ I P_�gB�f
�g .ascrcmnt****      � ****B b  P[CDC b  PWEFE m  PSGG �HH & S k i p p i n g   o t h e r   a p p  F o  SV�e�e 0 otherappname otherAppNameD m  WZII �JJ Z :   N o t   s u i t a b l e   ( e . g . ,   a l l   w i n d o w s   m i n i m i z e d ) .�f  ! K�dK l ``�c�b�a�c  �b  �a  �d  � R      �`L�_
�` .ascrerr ****      � ****L o      �^�^ &0 errmsgswitchother errMsgSwitchOther�_  � I iz�]M�\
�] .ascrcmnt****      � ****M b  ivNON b  itPQP b  ipRSR m  ilTT �UU H E r r o r   c h e c k i n g / a c t i v a t i n g   o t h e r   a p p  S o  lo�[�[ 0 otherappname otherAppNameQ m  psVV �WW  :  O o  tu�Z�Z &0 errmsgswitchother errMsgSwitchOther�\  ��  � 2 , theProcess is already a SE object reference   � �XX X   t h e P r o c e s s   i s   a l r e a d y   a   S E   o b j e c t   r e f e r e n c e�� 0 
theprocess 
theProcess� o  z}�Y�Y  0 otherprocesses otherProcesses�   End otherProcesses loop   � �YY 0   E n d   o t h e r P r o c e s s e s   l o o p��  ��  ��  f 1 + Final Check: If still no app was activated   g �ZZ V   F i n a l   C h e c k :   I f   s t i l l   n o   a p p   w a s   a c t i v a t e dd [\[ Z  ��]^�X�W] H  ��__ o  ���V�V 0 appfound appFound^ k  ��`` aba I ���Uc�T
�U .ascrcmnt****      � ****c m  ��dd �ee � N o   s u i t a b l e   a p p l i c a t i o n   w i t h   v i s i b l e / n o n - m i n i m i z e d   w i n d o w s   f o u n d   t o   s w i t c h   f o c u s   t o .�T  b fgf l ���Shi�S  h 7 1 Optional: Activate Finder as a default fallback?   i �jj b   O p t i o n a l :   A c t i v a t e   F i n d e r   a s   a   d e f a u l t   f a l l b a c k ?g klk l ���Rmn�R  m 
  try   n �oo    t r yl pqp l ���Qrs�Q  r . (   tell application "Finder" to activate   s �tt P       t e l l   a p p l i c a t i o n   " F i n d e r "   t o   a c t i v a t eq u�Pu l ���Ovw�O  v   end try   w �xx    e n d   t r y�P  �X  �W  \ y�Ny l ���M�L�K�M  �L  �K  �N  =   End of didMinimize check   > �zz 2   E n d   o f   d i d M i n i m i z e   c h e c k�H   R      �J{|
�J .ascrerr ****      � ****{ o      �I�I 0 errmsg errMsg| �H}�G
�H 
errn} o      �F�F 0 errnum errNum�G   k  ��~~ � l ���E���E  � 8 2 Handle any top-level unexpected errors gracefully   � ��� d   H a n d l e   a n y   t o p - l e v e l   u n e x p e c t e d   e r r o r s   g r a c e f u l l y� ��D� I ���C��B
�C .ascrcmnt****      � ****� b  ����� b  ����� b  ����� b  ����� m  ���� ��� , O v e r a l l   S c r i p t   E r r o r :  � o  ���A�A 0 errmsg errMsg� m  ���� ���    (� o  ���@�@ 0 errnum errNum� m  ���� ���  )�B  �D  �s  �r  �t       �?����>������=�<����;�:�9�?  � �8�7�6�5�4�3�2�1�0�/�.�-�,�+�*�)�8 0 writelogentry writeLogEntry
�7 .aevtoappnull  �   � ****�6 0 didminimize didMinimize�5 0 frontappname frontAppName�4 "0 frontappprocess frontAppProcess�3 *0 capturedwindowtitle capturedWindowTitle�2 0 frontwin frontWin�1 0 preferredapps preferredApps�0 0 appfound appFound�/ 0 canactivate canActivate�.  0 otherprocesses otherProcesses�- 0 otherappname otherAppName�, 0 
allwindows 
allWindows�+  �*  �)  � �( �'�&���%�( 0 writelogentry writeLogEntry�' �$��$ �  �#�"�# 0 appname appName�" 0 
windowname 
windowName�&  � �!� ������! 0 appname appName�  0 
windowname 
windowName� 0 logfilepath logFilePath� 0 logentry logEntry�  0 filedescriptor fileDescriptor� 0 errmsg errMsg� 0 errnum errNum� $���� 3 I K M�� `� f s y�� � ���������
�	� � ��� ���
� afdrcusr
� 
rtyp
� 
ctxt
� .earsffdralis        afdr
� .ascrcmnt****      � ****
� 
msng
� 
bool
� .misccurdldt    ��� null
� 
TEXT
� 
lnfd
� 
file
� 
perm
� .rdwropenshor       file
� 
refn
� 
wrat
� rdwreof �
 
�	 .rdwrwritnull���     ****
� .rdwrclosnull���     ****� 0 errmsg errMsg� ���
� 
errn� 0 errnum errNum�  �  �  �% ����l �%E�O�%�%�%�%j O�� 
 �� �& �j OhY hO�� 
 �� �& �j OhY hO*j a &a %�%a %�%_ %E�O =*a �/a el E�O�a �a a a  O�j Oa �%a %�%j W 'X   a !�%j O *a �/j W X " #h� ��� ������
� .aevtoappnull  �   � ****� k    ���  ���  ���  ���  ��� ����  �   ��  � �������������������������� 0 errmsg errMsg�� 0 errnum errNum�� 0 errmsginner errMsgInner�� 0 errnuminner errNumInner�� 0 appname appName�� 0 awindow aWindow�� 0 
errmsgloop 
errMsgLoop�� $0 errmsgswitchpref errMsgSwitchPref��  0 errmsgproclist errMsgProcList�� 0 
theprocess 
theProcess�� 0 errmsgloop2 errMsgLoop2�� &0 errmsgswitchother errMsgSwitchOther� u������������Z�������3��6@E����NT��W��k���������������������&CF��S��_{����������������2GLOY[kosw{�����������������������#%EG��W��o������������-/?GI��TVd����� 0 didminimize didMinimize
�� 
msng�� 0 frontappname frontAppName�� "0 frontappprocess frontAppProcess�� *0 capturedwindowtitle capturedWindowTitle
�� .ascrcmnt****      � ****
�� 
pcap�  
�� 
pisf
�� 
pnam
�� 
bool�� 0 errmsg errMsg��  
�� 
appr
�� .sysonotfnull��� ��� TEXT
�� 
cwin
�� .coredoexnull���     ****�� 0 frontwin frontWin
�� 
butT
�� .prcsclicnull��� ��� uiel�� 0 writelogentry writeLogEntry� ������
�� 
errn�� 0 errnum errNum��  
�� 
attr
�� 
valL
�� 
capp
�� 
prun
�� .corecnte****       ****
�� 
pmnd�� 0 errmsginner errMsgInner� ������
�� 
errn�� 0 errnuminner errNumInner��  �� �� 0 preferredapps preferredApps�� 0 appfound appFound
�� 
kocl
�� 
cobj�� 0 canactivate canActivate
�� 
pvis�� 0 
theprocess 
theProcess�� 0 
allwindows 
allWindows�� 0 
errmsgloop 
errMsgLoop
�� .miscactvnull��� ��� null�� $0 errmsgswitchpref errMsgSwitchPref
�� 
bkgo��  0 otherprocesses otherProcesses��  0 errmsgproclist errMsgProcList�� 0 otherappname otherAppName�� 0 errmsgloop2 errMsgLoop2�� &0 errmsgswitchother errMsgSwitchOther���fE�O�E�O�E�O�E�O��j O� c A*�k/�[�,\Ze81E�O��,E�O�� 
 �� �& 	)j�Y hO���,%a %�%j W !X  a �%j Oa a a l OhUO� �a j O�E�O �� �� �*a k/j  )ja Y hO*a k/E` O_ �,E�O�� 
 	�a  �& )ja Y hO_ a a  /j  )ja !�%Y hO_ a a "/j #Oa $�%j O)��l+ %OeE�OPUUW X  &a '�%j Y hO� �a (j O�E�O ~� v� q*a k/j  )ja )Y hO*a k/E` O_ �,E�O�� 
 	�a * �& )ja +Y hOe_ a ,a -/a .,FOa /�%j O)��l+ %OeE�OPUUW X  &a 0�%j Y hO� �a 1�%j O�E�O �*a 2�/a 3,e  )j�a 4%Y hO*a 2�/ �*a -j 5j  )j�a 6%Y hO T*a k/E` O_ �,E�O�� 
 	�a 7 �& )ja 8Y hOe_ a 9,FOa :�%j O)��l+ %OeE�OPW X ; <)ja =�%OPUOPW X  &a >�%j Y hO� a ?j Oa @a a Al Y�a B�%a C%j Oa Da Ea Fa Ga Ha Ia Ja Ka LvE` MOfE` NOa Oj O_ M[a Pa Ql 5kh �� �fE` RO �� �*�/�[a S,\Ze81j  �*�/E` TO_ Ta k/j  d_ Ta -E` UO P_ U[a Pa Ql 5kh  !�a ,a V/a .,f  eE` ROY hW X W a X�%a Y%�%j [OY��OPY hY hUO_ R 4a Z�%a [%j O*a 2�/ *j \UOeE` NOa ]�%j OY hOPW X ^ hY h[OY�O_ N^a _j O� E -*�-�[[[a S,\Ze8\[�,\Z�9A\[a `,\Zf8A1E` aW X b jvE` aOa c�%j UO_ a[a Pa Ql 5kh 	��,E` dOfE` RO �� p�a k/j  b�a -E` UO R_ U[a Pa Ql 5kh  !�a ,a e/a .,f  eE` ROY hW X f a g_ d%a h%�%j [OY��Y hUO_ R :a i_ d%a j%j O*a 2_ d/ *j \UOeE` NOa k_ d%j OY a l_ d%a m%j OPW X n a o_ d%a p%�%j [OY�Y hO_ N a qj OPY hOPW X  &a r�%a s%�%a t%j 
�> boovtrue� ���  S c r i p t   E d i t o r� �� Z���
�� 
pcap� ���  S c r i p t   E d i t o r� ��� * a c t i v a t e - w i n d o w s . s c p t� �� ����� Z���
�� 
pcap� ���  S c r i p t   E d i t o r
�� 
cwin� ��� * a c t i v a t e - w i n d o w s . s c p t� ����� �  kosw{��
�= boovtrue
�< boovtrue� ����� 	� 	 ���������� �� Z���
�� 
pcap� ���  S p o t i f y� �� Z���
�� 
pcap� ���  T e r m i n a l� �� Z���
�� 
pcap� ���  D i s c o r d� �� Z���
�� 
pcap� ���  U n i t y   H u b� �� Z���
�� 
pcap� ���  F i n d e r� �� Z���
�� 
pcap� ���  S a f a r i� �� Z���
�� 
pcap� ���  E l e c t r o n� �� Z���
�� 
pcap� ���  O b s i d i a n� �� Z���
�� 
pcap� ���  C h a t G P T� ���  S p o t i f y� ����� �  �� �� ����� Z���
�� 
pcap� ���  S p o t i f y
�� 
cwin� ��� * T O O L   -   R o s e t t a   S t o n e d�;  �:  �9   ascr  ��ޭ