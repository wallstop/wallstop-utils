FasdUAS 1.101.10   ��   ��    k             l     ��  ��    I C Restore the most recently minimized window across all applications     � 	 	 �   R e s t o r e   t h e   m o s t   r e c e n t l y   m i n i m i z e d   w i n d o w   a c r o s s   a l l   a p p l i c a t i o n s   
  
 l   + ����  Q    +     k          l   ��  ��    P J Initialize a list to hold minimized windows as lists of {process, window}     �   �   I n i t i a l i z e   a   l i s t   t o   h o l d   m i n i m i z e d   w i n d o w s   a s   l i s t s   o f   { p r o c e s s ,   w i n d o w }      r        J    ����    o      ���� $0 minimizedwindows minimizedWindows      l   ��������  ��  ��        l   ��  ��    B < Access System Events to interact with application processes     �     x   A c c e s s   S y s t e m   E v e n t s   t o   i n t e r a c t   w i t h   a p p l i c a t i o n   p r o c e s s e s   ! " ! O    x # $ # k    w % %  & ' & l   �� ( )��   ( 8 2 Iterate through all visible application processes    ) � * * d   I t e r a t e   t h r o u g h   a l l   v i s i b l e   a p p l i c a t i o n   p r o c e s s e s '  +�� + X    w ,�� - , k    r . .  / 0 / l   �� 1 2��   1 0 * Skip background or invisible applications    2 � 3 3 T   S k i p   b a c k g r o u n d   o r   i n v i s i b l e   a p p l i c a t i o n s 0  4�� 4 Z    r 5 6���� 5 =   # 7 8 7 n    ! 9 : 9 1    !��
�� 
pvis : o    ���� 0 proc   8 m   ! "��
�� boovtrue 6 k   & n ; ;  < = < l  & &�� > ?��   > 5 / Iterate through each window of the application    ? � @ @ ^   I t e r a t e   t h r o u g h   e a c h   w i n d o w   o f   t h e   a p p l i c a t i o n =  A�� A X   & n B�� C B Q   8 i D E�� D k   ; ` F F  G H G l  ; ;�� I J��   I R L Check if the window is minimized (AXMinimized attribute exists and is true)    J � K K �   C h e c k   i f   t h e   w i n d o w   i s   m i n i m i z e d   ( A X M i n i m i z e d   a t t r i b u t e   e x i s t s   a n d   i s   t r u e ) H  L�� L Z   ; ` M N���� M l  ; C O���� O I  ; C�� P��
�� .coredoexnull���     **** P n   ; ? Q R Q 4   < ?�� S
�� 
attr S m   = > T T � U U  A X M i n i m i z e d R o   ; <���� 0 win  ��  ��  ��   N Z   F \ V W���� V =  F N X Y X n   F L Z [ Z 1   J L��
�� 
valL [ n   F J \ ] \ 4   G J�� ^
�� 
attr ^ m   H I _ _ � ` `  A X M i n i m i z e d ] o   F G���� 0 win   Y m   L M��
�� boovtrue W k   Q X a a  b c b l  Q Q�� d e��   d 7 1 Add the process and window to the list as a list    e � f f b   A d d   t h e   p r o c e s s   a n d   w i n d o w   t o   t h e   l i s t   a s   a   l i s t c  g�� g r   Q X h i h J   Q U j j  k l k o   Q R���� 0 proc   l  m�� m o   R S���� 0 win  ��   i n       n o n  ;   V W o o   U V���� $0 minimizedwindows minimizedWindows��  ��  ��  ��  ��  ��   E R      ������
�� .ascrerr ****      � ****��  ��  ��  �� 0 win   C n   ) , p q p 2  * ,��
�� 
cwin q o   ) *���� 0 proc  ��  ��  ��  ��  �� 0 proc   - 2   ��
�� 
pcap��   $ m    	 r r�                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��   "  s t s l  y y��������  ��  ��   t  u v u l  y y�� w x��   w / ) Check if there are any minimized windows    x � y y R   C h e c k   i f   t h e r e   a r e   a n y   m i n i m i z e d   w i n d o w s v  z { z Z   y | }���� | ?   y � ~  ~ l  y ~ ����� � I  y ~�� ���
�� .corecnte****       **** � o   y z���� $0 minimizedwindows minimizedWindows��  ��  ��    m   ~ ����   } k   �
 � �  � � � l  � ��� � ���   � H B Assume the last window in the list is the most recently minimized    � � � � �   A s s u m e   t h e   l a s t   w i n d o w   i n   t h e   l i s t   i s   t h e   m o s t   r e c e n t l y   m i n i m i z e d �  � � � r   � � � � � n   � � � � � 4  � ��� �
�� 
cobj � m   � ������� � o   � ����� $0 minimizedwindows minimizedWindows � o      ���� 0 lastminimized lastMinimized �  � � � r   � � � � � n   � � � � � 4   � ��� �
�� 
cobj � m   � �����  � o   � ����� 0 lastminimized lastMinimized � o      ���� 0 theproc theProc �  � � � r   � � � � � n   � � � � � 4   � ��� �
�� 
cobj � m   � �����  � o   � ����� 0 lastminimized lastMinimized � o      ���� 0 thewin theWin �  � � � l  � ���������  ��  ��   �  � � � l  � ��� � ���   � 1 + Restore the window using Accessibility API    � � � � V   R e s t o r e   t h e   w i n d o w   u s i n g   A c c e s s i b i l i t y   A P I �  � � � O   � � � � � O   � � � � � O   � � � � � Q   � � � � � � r   � � � � � m   � ���
�� boovfals � n       � � � 1   � ���
�� 
valL � 4   � ��� �
�� 
attr � m   � � � � � � �  A X M i n i m i z e d � R      �� ���
�� .ascrerr ****      � **** � o      ���� 0 errmsg errMsg��   � k   � � � �  � � � l  � ��� � ���   � I C If setting AXMinimized fails, attempt to click the Minimize button    � � � � �   I f   s e t t i n g   A X M i n i m i z e d   f a i l s ,   a t t e m p t   t o   c l i c k   t h e   M i n i m i z e   b u t t o n �  ��� � Q   � � � ��� � Z   � � � ����� � I  � ��� ���
�� .coredoexnull���     **** � l  � � ����� � n   � � � � � 4   � ��� �
�� 
butT � m   � � � � � � �  M i n i m i z e � o   � ����� 0 thewin theWin��  ��  ��   � I  � ��� ���
�� .prcsclicnull��� ��� uiel � n   � � � � � 4   � ��� �
�� 
butT � m   � � � � � � �  M i n i m i z e � o   � ����� 0 thewin theWin��  ��  ��   � R      ������
�� .ascrerr ****      � ****��  ��  ��  ��   � o   � ����� 0 thewin theWin � o   � ����� 0 theproc theProc � m   � � � ��                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��   �  � � � l  � ���������  ��  ��   �  � � � l  � ��� � ���   � . ( Bring the application to the foreground    � � � � P   B r i n g   t h e   a p p l i c a t i o n   t o   t h e   f o r e g r o u n d �  ��� � O   �
 � � � I 	������
�� .miscactvnull��� ��� null��  ��   � 4   ��� �
�� 
capp � l  �  ����� � n   �  � � � 1   � ���
�� 
pnam � o   � ����� 0 theproc theProc��  ��  ��  ��  ��   {  ��� � l ��������  ��  ��  ��    R      �� � �
�� .ascrerr ****      � **** � o      ���� 0 errmsg errMsg � �� ��
�� 
errn � o      �~�~ 0 errnum errNum�    k  + � �  � � � l �} � ��}   � . ( Handle any unexpected errors gracefully    � � � � P   H a n d l e   a n y   u n e x p e c t e d   e r r o r s   g r a c e f u l l y �  ��| � I +�{ � �
�{ .sysodisAaleR        TEXT � m   � � � � � , E r r o r   R e s t o r i n g   W i n d o w � �z � �
�z 
mesS � o  �y�y 0 errmsg errMsg � �x ��w
�x 
as A � m  "%�v
�v EAlTwarN�w  �|  ��  ��     � � � l     �u�t�s�u  �t  �s   �  � � � l     �r � ��r   � C = Script Version 2: Restore the Most Recently Minimized Window    � � � � z   S c r i p t   V e r s i o n   2 :   R e s t o r e   t h e   M o s t   R e c e n t l y   M i n i m i z e d   W i n d o w �  � � � l     �q�p�o�q  �p  �o   �  � � � l     �n � ��n   � ' ! Define the path for the log file    � � � � B   D e f i n e   t h e   p a t h   f o r   t h e   l o g   f i l e �  � � � l ,A �m�l  r  ,A b  ,= l ,9�k�j I ,9�i
�i .earsffdralis        afdr m  ,/�h
�h afdrcusr �g�f
�g 
rtyp m  25�e
�e 
ctxt�f  �k  �j   m  9<		 �

 2 m i n i m i z e d _ w i n d o w s _ l o g . t x t o      �d�d 0 logfilepath logFilePath�m  �l   �  l     �c�b�a�c  �b  �a    l B��`�_ Q  B� k  Ev  l EE�^�^   H B Step 1: Read the log file and get the last minimized window entry    � �   S t e p   1 :   R e a d   t h e   l o g   f i l e   a n d   g e t   t h e   l a s t   m i n i m i z e d   w i n d o w   e n t r y  r  EL m  EH �   o      �]�] 0 	lastentry 	lastEntry   Q  M�!"#! k  P�$$ %&% r  P`'(' I P\�\)�[
�\ .rdwrread****        ****) 4  PX�Z*
�Z 
file* o  TW�Y�Y 0 logfilepath logFilePath�[  ( o      �X�X 0 filecontents fileContents& +,+ r  al-.- n  ah/0/ 2 dh�W
�W 
cpar0 o  ad�V�V 0 filecontents fileContents. o      �U�U 0 
allentries 
allEntries, 1�T1 Z  m�23�S42 ?  mv565 l mt7�R�Q7 I mt�P8�O
�P .corecnte****       ****8 o  mp�N�N 0 
allentries 
allEntries�O  �R  �Q  6 m  tu�M�M  3 r  y�9:9 n  y;<; 4 |�L=
�L 
cobj= m  }~�K�K��< o  y|�J�J 0 
allentries 
allEntries: o      �I�I 0 	lastentry 	lastEntry�S  4 k  ��>> ?@? I ���HAB
�H .sysonotfnull��� ��� TEXTA m  ��CC �DD L N o   m i n i m i z e d   w i n d o w s   f o u n d   i n   t h e   l o g .B �GE�F
�G 
apprE m  ��FF �GG  R e s t o r e   W i n d o w�F  @ H�EH l ��IJKI L  ���D�D  J   Exit if the log is empty   K �LL 2   E x i t   i f   t h e   l o g   i s   e m p t y�E  �T  " R      �CMN
�C .ascrerr ****      � ****M o      �B�B 0 errmsg errMsgN �AO�@
�A 
errnO o      �?�? 0 errnum errNum�@  # k  ��PP QRQ I ���>ST
�> .sysonotfnull��� ��� TEXTS b  ��UVU m  ��WW �XX 2 F a i l e d   t o   r e a d   l o g   f i l e :  V o  ���=�= 0 errmsg errMsgT �<Y�;
�< 
apprY m  ��ZZ �[[  R e s t o r e   W i n d o w�;  R \�:\ l ��]^_] L  ���9�9  ^ / ) Exit if there's an error reading the log   _ �`` R   E x i t   i f   t h e r e ' s   a n   e r r o r   r e a d i n g   t h e   l o g�:    aba l ���8�7�6�8  �7  �6  b cdc Z  ��ef�5�4e = ��ghg o  ���3�3 0 	lastentry 	lastEntryh m  ��ii �jj  f l ��klmk L  ���2�2  l    Exit if no entry is found   m �nn 4   E x i t   i f   n o   e n t r y   i s   f o u n d�5  �4  d opo l ���1�0�/�1  �0  �/  p qrq l ���.st�.  s K E Step 2: Parse the log entry to get application name and window title   t �uu �   S t e p   2 :   P a r s e   t h e   l o g   e n t r y   t o   g e t   a p p l i c a t i o n   n a m e   a n d   w i n d o w   t i t l er vwv r  ��xyx m  ��zz �{{    |  y n     |}| 1  ���-
�- 
txdl} 1  ���,
�, 
ascrw ~~ r  ����� n  ����� 2 ���+
�+ 
citm� o  ���*�* 0 	lastentry 	lastEntry� o      �)�) 0 
entryparts 
entryParts ��� r  ����� m  ���� ���  � n     ��� 1  ���(
�( 
txdl� 1  ���'
�' 
ascr� ��� l ���&�%�$�&  �%  �$  � ��� Z  ����#�"� A  ����� l ����!� � I �����
� .corecnte****       ****� o  ���� 0 
entryparts 
entryParts�  �!  �   � m  ���� � k  ��� ��� I �����
� .sysonotfnull��� ��� TEXT� m  ���� ��� 2 I n v a l i d   l o g   e n t r y   f o r m a t .� ���
� 
appr� m  ���� ���  R e s t o r e   W i n d o w�  � ��� l  ���� L   ��  � ) # Exit if the log entry is malformed   � ��� F   E x i t   i f   t h e   l o g   e n t r y   i s   m a l f o r m e d�  �#  �"  � ��� l ����  �  �  � ��� r  ��� n  ��� 4  
��
� 
cobj� m  �� � o  
�� 0 
entryparts 
entryParts� o      �� 0 logdate logDate� ��� r  ��� n  ��� 4  ��
� 
cobj� m  �� � o  �� 0 
entryparts 
entryParts� o      �� 0 
logappname 
logAppName� ��� r  '��� n  #��� 4   #��
� 
cobj� m  !"�
�
 � o   �	�	 0 
entryparts 
entryParts� o      ��  0 logwindowtitle logWindowTitle� ��� l ((����  �  �  � ��� l ((����  � ' ! Step 3: Activate the application   � ��� B   S t e p   3 :   A c t i v a t e   t h e   a p p l i c a t i o n� ��� O  (9��� I 38���
� .miscactvnull��� ��� null�  �  � 4  (0� �
�  
capp� o  ,/���� 0 
logappname 
logAppName� ��� l ::��������  ��  ��  � ��� l :A���� I :A�����
�� .sysodelanull��� ��� nmbr� m  :=�� ?�      ��  � 0 * Wait for the application to become active   � ��� T   W a i t   f o r   t h e   a p p l i c a t i o n   t o   b e c o m e   a c t i v e� ��� l BB��������  ��  ��  � ��� l BB������  � = 7 Step 4: Unminimize the window using Accessibility APIs   � ��� n   S t e p   4 :   U n m i n i m i z e   t h e   w i n d o w   u s i n g   A c c e s s i b i l i t y   A P I s� ��� O  B���� O  F���� k  O��� ��� l OO������  � . ( Find the window with the matching title   � ��� P   F i n d   t h e   w i n d o w   w i t h   t h e   m a t c h i n g   t i t l e� ��� r  Of��� 6 Ob��� 4 OS���
�� 
cwin� m  QR���� � = Va��� 1  W[��
�� 
pnam� o  \`����  0 logwindowtitle logWindowTitle� o      ���� 0 targetwindow targetWindow� ���� Z  g������� l gs������ I gs�����
�� .coredoexnull���     ****� n  go��� 4  jo���
�� 
attr� m  kn�� ���  A X M i n i m i z e d� o  gj���� 0 targetwindow targetWindow��  ��  ��  � r  v���� m  vw��
�� boovfals� n      ��� 1  ���
�� 
valL� n  w��� 4  z���
�� 
attr� m  {~   �  A X M i n i m i z e d� o  wz���� 0 targetwindow targetWindow��  � k  ��  l ������   Z T If AXMinimized attribute doesn't exist, try using the standard AppleScript property    � �   I f   A X M i n i m i z e d   a t t r i b u t e   d o e s n ' t   e x i s t ,   t r y   u s i n g   t h e   s t a n d a r d   A p p l e S c r i p t   p r o p e r t y �� O  ��	
	 r  �� m  ����
�� boovfals n       1  ����
�� 
pmnd o  ������ 0 targetwindow targetWindow
 4  ����
�� 
capp o  ������ 0 
logappname 
logAppName��  ��  � 4  FL��
�� 
pcap o  HK���� 0 
logappname 
logAppName� m  BC�                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  �  l ����������  ��  ��    l ������   6 0 Step 5: Remove the last entry from the log file    � `   S t e p   5 :   R e m o v e   t h e   l a s t   e n t r y   f r o m   t h e   l o g   f i l e  Q  �Z k  �*   r  ��!"! J  ������  " o      ���� 0 newlog newLog  #$# Y  ��%��&'��% r  ��()( n  ��*+* 4  ����,
�� 
cobj, o  ������ 0 i  + o  ������ 0 
allentries 
allEntries) n      -.-  ;  ��. o  ������ 0 newlog newLog�� 0 i  & m  ������ ' \  ��/0/ l ��1����1 I ����2��
�� .corecnte****       ****2 o  ������ 0 
allentries 
allEntries��  ��  ��  0 m  ������ ��  $ 343 l ����������  ��  ��  4 565 r  ��787 o  ����
�� 
ret 8 n     9:9 1  ����
�� 
txdl: 1  ����
�� 
ascr6 ;<; r  ��=>= c  ��?@? o  ������ 0 newlog newLog@ m  ����
�� 
ctxt> o      ���� 0 
updatedlog 
updatedLog< ABA r  ��CDC m  ��EE �FF  D n     GHG 1  ����
�� 
txdlH 1  ����
�� 
ascrB IJI l ����������  ��  ��  J KLK l ����MN��  M - ' Write the updated log back to the file   N �OO N   W r i t e   t h e   u p d a t e d   l o g   b a c k   t o   t h e   f i l eL PQP r  �RSR I ����TU
�� .rdwropenshor       fileT 4  ����V
�� 
fileV o  ������ 0 logfilepath logFilePathU ��W��
�� 
permW m  ����
�� boovtrue��  S o      ����  0 filedescriptor fileDescriptorQ XYX l Z[\Z I ��]^
�� .rdwrseofnull���     ****] o  ����  0 filedescriptor fileDescriptor^ ��_��
�� 
set2_ m  	
����  ��  [   Clear the file   \ �``    C l e a r   t h e   f i l eY aba I "��cd
�� .rdwrwritnull���     ****c o  ���� 0 
updatedlog 
updatedLogd ��ef
�� 
refne o  ����  0 filedescriptor fileDescriptorf ��g��
�� 
wratg m  ����  ��  b h��h I #*��i��
�� .rdwrclosnull���     ****i o  #&����  0 filedescriptor fileDescriptor��  ��   R      ��jk
�� .ascrerr ****      � ****j o      ���� 0 errmsg errMsgk ��l��
�� 
errnl o      ���� 0 errnum errNum��   k  2Zmm non Q  2Jpq��p I 5A��r��
�� .rdwrclosnull���     ****r 4  5=��s
�� 
files o  9<���� 0 logfilepath logFilePath��  q R      ������
�� .ascrerr ****      � ****��  ��  ��  o t��t I KZ��uv
�� .sysonotfnull��� ��� TEXTu b  KPwxw m  KNyy �zz 6 F a i l e d   t o   u p d a t e   l o g   f i l e :  x o  NO���� 0 errmsg errMsgv ��{��
�� 
appr{ m  SV|| �}}  R e s t o r e   W i n d o w��  ��   ~~ l [[��������  ��  ��   ��� I [t����
�� .sysonotfnull��� ��� TEXT� b  [j��� b  [f��� b  [b��� m  [^�� ��� " R e s t o r e d   w i n d o w :  � o  ^a����  0 logwindowtitle logWindowTitle� m  be�� ���    f r o m  � o  fi���� 0 
logappname 
logAppName� �����
�� 
appr� m  mp�� ���  R e s t o r e   W i n d o w��  � ���� l uu��������  ��  ��  ��   R      ����
�� .ascrerr ****      � ****� o      ���� 0 errmsg errMsg� �����
�� 
errn� o      �� 0 errnum errNum��   k  ~��� ��� l ~~�~���~  � . ( Handle any unexpected errors gracefully   � ��� P   H a n d l e   a n y   u n e x p e c t e d   e r r o r s   g r a c e f u l l y� ��}� I ~��|��
�| .sysodisAaleR        TEXT� m  ~��� ��� , E r r o r   R e s t o r i n g   W i n d o w� �{��
�{ 
mesS� o  ���z�z 0 errmsg errMsg� �y��x
�y 
as A� m  ���w
�w EAlTwarN�x  �}  �`  �_   ��� l     �v�u�t�v  �u  �t  � ��s� l     �r�q�p�r  �q  �p  �s       �o�����������n�m�l�k�j�i�h�o  � �g�f�e�d�c�b�a�`�_�^�]�\�[�Z�Y�X
�g .aevtoappnull  �   � ****�f $0 minimizedwindows minimizedWindows�e 0 lastminimized lastMinimized�d 0 theproc theProc�c 0 thewin theWin�b 0 logfilepath logFilePath�a 0 	lastentry 	lastEntry�` 0 filecontents fileContents�_ 0 
allentries 
allEntries�^  �]  �\  �[  �Z  �Y  �X  � �W��V�U���T
�W .aevtoappnull  �   � ****� k    ���  
��  ��� �S�S  �V  �U  � �R�Q�P�O�N�R 0 proc  �Q 0 win  �P 0 errmsg errMsg�O 0 errnum errNum�N 0 i  � [�M r�L�K�J�I�H�G�F T�E _�D�C�B�A�@�? ��>�= � ��<�;�:�9� ��8�7�6�5�4�3�2�1�0	�/�.�-�,�+�*�)C�(F�'WZiz�&�%�$�#����"�!� ����� ����E���������y|�����M $0 minimizedwindows minimizedWindows
�L 
pcap
�K 
kocl
�J 
cobj
�I .corecnte****       ****
�H 
pvis
�G 
cwin
�F 
attr
�E .coredoexnull���     ****
�D 
valL�C  �B  �A 0 lastminimized lastMinimized�@ 0 theproc theProc�? 0 thewin theWin�> 0 errmsg errMsg
�= 
butT
�< .prcsclicnull��� ��� uiel
�; 
capp
�: 
pnam
�9 .miscactvnull��� ��� null� ���
� 
errn� 0 errnum errNum�  
�8 
mesS
�7 
as A
�6 EAlTwarN�5 
�4 .sysodisAaleR        TEXT
�3 afdrcusr
�2 
rtyp
�1 
ctxt
�0 .earsffdralis        afdr�/ 0 logfilepath logFilePath�. 0 	lastentry 	lastEntry
�- 
file
�, .rdwrread****        ****�+ 0 filecontents fileContents
�* 
cpar�) 0 
allentries 
allEntries
�( 
appr
�' .sysonotfnull��� ��� TEXT
�& 
ascr
�% 
txdl
�$ 
citm�# 0 
entryparts 
entryParts�" 0 logdate logDate�! 0 
logappname 
logAppName�   0 logwindowtitle logWindowTitle
� .sysodelanull��� ��� nmbr�  � 0 targetwindow targetWindow
� 
pmnd� 0 newlog newLog
� 
ret � 0 
updatedlog 
updatedLog
� 
perm
� .rdwropenshor       file�  0 filedescriptor fileDescriptor
� 
set2
� .rdwrseofnull���     ****
� 
refn
� 
wrat
� .rdwrwritnull���     ****
� .rdwrclosnull���     ****�T�jvE�O� m j*�-[��l kh  ��,e  M G��-[��l kh  *���/j 
 ���/�,e  ��lv�6FY hY hW X  h[OY��Y h[OY��UO�j j ���i/E�O��k/E` O��l/E` O� T_  M_  F f*�a /�,FW 6X   (_ a a /j 
 _ a a /j Y hW X  hUUUO*a _ a ,E/ *j UY hOPW X  a a �a a a   !Oa "a #a $l %a &%E` 'O6a (E` )O K*a *_ '/j +E` ,O_ ,a --E` .O_ .j j _ .�i/E` )Y a /a 0a 1l 2OhW X  a 3�%a 0a 4l 2OhO_ )a 5  hY hOa 6_ 7a 8,FO_ )a 9-E` :Oa ;_ 7a 8,FO_ :j m a <a 0a =l 2OhY hO_ :�k/E` >O_ :�l/E` ?O_ :�m/E` @O*a _ ?/ *j UOa Aj BO� W*�_ ?/ M*�k/a C[a ,\Z_ @81E` DO_ D�a E/j 
 f_ D�a F/�,FY *a _ ?/ f_ Da G,FUUUO �jvE` HO !k_ .j kkh _ .�/_ H6F[OY��O_ I_ 7a 8,FO_ Ha $&E` JOa K_ 7a 8,FO*a *_ '/a Lel ME` NO_ Na Ojl PO_ Ja Q_ Na Rja   SO_ Nj TW /X   *a *_ '/j TW X  hOa U�%a 0a Vl 2Oa W_ @%a X%_ ?%a 0a Yl 2OPW X  a Za �a a a   !� ��� �  �����������
�	����� ��� �  ��� �� ����  r�
� 
pcap
� 
cobj� � �� �� ��� ���
�� 
cwin
�  
cobj�� � ����� �  ��� �� �����
�� 
cobj�� � �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� � �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� $� �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� (� �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� -� �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� 2� �� ������ ���
�� 
cwin
�� 
cobj�� � ����� �  ��� �� �����
�� 
cobj�� 9� �� ������ ���
�� 
cwin
�� 
cobj�� �  �  �
  �	  �  �  �  �  � ����� �  ��� �� ������  r��
�� 
pcap
�� 
cobj�� � �� ������ ���
�� 
cwin
�� 
cobj�� � ��� j M a c i n t o s h   H D : U s e r s : w a l l s t o p : m i n i m i z e d _ w i n d o w s _ l o g . t x t� ���  � ���N W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   5 : 5 7 : 4 5 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   5 : 5 8 : 4 3 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 2 : 4 5 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 3 : 5 2 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 5 : 4 6 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 0 2 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 0 9 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 5 4 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 8 : 1 8 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 9 : 4 6 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
 W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 0 : 3 6 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 0 4 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 4 2 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 4 6 ? P M   |   S a f a r i   |   C h a t G P T 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 5 0 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 4 : 1 1 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 5 : 3 4 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 2 0 : 5 0 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 6 7 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 2 7 : 3 1 ? P M   |   S a f a r i   |   w a l l s t o p   s t u d i o s 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 3 5 : 4 3 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 3 6 : 3 5 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 7 : 5 4 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 8 : 0 2 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 9 : 3 5 ? P M   |   S a f a r i   |   A p p l e S c r i p t   M i n i m i z e   W i n d o w 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 3 : 1 9 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 4 : 3 8 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
  F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 8 : 0 7 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w 
 � ����� -� 0 ����� 	
 !"#$%&�������� �'' � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   5 : 5 7 : 4 5 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w� �(( � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   5 : 5 8 : 4 3 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w� �)) � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 2 : 4 5 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w� �** � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 3 : 5 2 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w� �++ � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 5 : 4 6 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2  �,, � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 0 2 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �-- � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 0 9 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7 �.. � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 6 : 5 4 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2 �// � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 8 : 1 8 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �00 � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 0 9 : 4 6 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �11 � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 0 : 3 6 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �22   �33 � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 0 4 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �44  	 �55 � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 4 2 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 3 2
 �66   �77 x W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 4 6 ? P M   |   S a f a r i   |   C h a t G P T �88   �99 � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 1 : 5 0 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7 �::   �;; � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 4 : 1 1 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �<<   �== � W e d n e s d a y ,   O c t o b e r   3 0 ,   2 0 2 4   a t   6 : 1 5 : 3 4 ? P M   |   T e r m i n a l   |   w a l l s t o p      w a l l s t o p @ E l i s - M a c B o o k - P r o      ~      - z s h      1 2 0 * 6 7 �>>   �?? F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 2 0 : 5 0 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 6 7 �@@   �AA � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 2 7 : 3 1 ? P M   |   S a f a r i   |   w a l l s t o p   s t u d i o s �BB   �CC F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 3 5 : 4 3 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 �DD   �EE F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 3 6 : 3 5 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 �FF   �GG � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 7 : 5 4 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w �HH   �II F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 8 : 0 2 ? P M   |   T e r m i n a l   |   w a l l s t o p - s t u d i o s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . l s t o p - s t u d i o s      - z s h      1 2 0 * 3 2 �JJ   �KK � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 4 9 : 3 5 ? P M   |   S a f a r i   |   A p p l e S c r i p t   M i n i m i z e   W i n d o w  �LL  ! �MM � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 3 : 1 9 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w" �NN  # �OO � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 4 : 3 8 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w$ �PP  % �QQ � F r i d a y ,   N o v e m b e r   1 ,   2 0 2 4   a t   8 : 5 8 : 0 7 ? P M   |   S c r i p t   E d i t o r   |   m i n i m i z e - w i n d o w& �RR  ��  ��  ��  �n  �m  �l  �k  �j  �i  �h   ascr  ��ޭ