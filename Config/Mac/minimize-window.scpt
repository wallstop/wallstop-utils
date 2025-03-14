FasdUAS 1.101.10   ��   ��    k             l     ��  ��    a [ Version 5: Utilizing AppleScript's `application "AppName"` and Checking for Running Status     � 	 	 �   V e r s i o n   5 :   U t i l i z i n g   A p p l e S c r i p t ' s   ` a p p l i c a t i o n   " A p p N a m e " `   a n d   C h e c k i n g   f o r   R u n n i n g   S t a t u s   
  
 l     ����  r         b     	    l     ����  I    ��  
�� .earsffdralis        afdr  m     ��
�� afdrcusr  �� ��
�� 
rtyp  m    ��
�� 
ctxt��  ��  ��    m       �   2 m i n i m i z e d _ w i n d o w s _ l o g . t x t  o      ���� 0 logfilepath logFilePath��  ��        l   ����  Q        k   �       l   ��   !��     : 4 Step 1: Identify the frontmost (active) application    ! � " " h   S t e p   1 :   I d e n t i f y   t h e   f r o n t m o s t   ( a c t i v e )   a p p l i c a t i o n   # $ # O    ) % & % k    ( ' '  ( ) ( r    " * + * 6     , - , 4   �� .
�� 
pcap . m    ����  - =    / 0 / 1    ��
�� 
pisf 0 m    ��
�� boovtrue + o      ���� "0 frontappprocess frontAppProcess )  1�� 1 r   # ( 2 3 2 n   # & 4 5 4 1   $ &��
�� 
pnam 5 o   # $���� "0 frontappprocess frontAppProcess 3 o      ���� 0 frontappname frontAppName��   & m     6 6�                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��   $  7 8 7 l  * *��������  ��  ��   8  9 : 9 r   * - ; < ; m   * +��
�� boovfals < o      ���� 0 didminimize didMinimize :  = > = l  . .��������  ��  ��   >  ? @ ? Z   . � A B���� A =  . 1 C D C o   . /���� 0 didminimize didMinimize D m   / 0��
�� boovfals B O   4 � E F E O   8 � G H G k   < � I I  J K J l  < <�� L M��   L / ) Check if the application has any windows    M � N N R   C h e c k   i f   t h e   a p p l i c a t i o n   h a s   a n y   w i n d o w s K  O P O r   < B Q R Q 4  < @�� S
�� 
cwin S m   > ?����  R o      ���� 0 frontwin frontWin P  T U T l  C C��������  ��  ��   U  V W V l  C C�� X Y��   X + % Attempt to click the Minimize button    Y � Z Z J   A t t e m p t   t o   c l i c k   t h e   M i n i m i z e   b u t t o n W  [�� [ Z   C � \ ]���� \ I  C O�� ^��
�� .coredoexnull���     **** ^ l  C K _���� _ n   C K ` a ` 4   D K�� b
�� 
butT b m   G J c c � d d  M i n i m i z e a o   C D���� 0 frontwin frontWin��  ��  ��   ] k   R � e e  f g f I  R ^�� h��
�� .prcsclicnull��� ��� uiel h n   R Z i j i 4   S Z�� k
�� 
butT k m   V Y l l � m m  M i n i m i z e j o   R S���� 0 frontwin frontWin��   g  n o n r   _ f p q p n   _ b r s r 1   ` b��
�� 
pnam s o   _ `���� 0 frontwin frontWin q o      ���� ,0 minimizedwindowtitle minimizedWindowTitle o  t u t r   g � v w v b   g � x y x b   g � z { z b   g ~ | } | b   g z ~  ~ b   g v � � � b   g t � � � l  g p ����� � c   g p � � � l  g l ����� � I  g l������
�� .misccurdldt    ��� null��  ��  ��  ��   � m   l o��
�� 
TEXT��  ��   � m   p s � � � � �    |   � o   t u���� 0 frontappname frontAppName  m   v y � � � � �    |   } n   z } � � � 1   { }��
�� 
pnam � o   z {���� 0 frontwin frontWin { 1   ~ ���
�� 
lnfd y o   � ���
�� 
ret  w o      ���� 0 logentry logEntry u  ��� � r   � � � � � m   � ���
�� boovtrue � o      ���� 0 didminimize didMinimize��  ��  ��  ��   H o   8 9���� "0 frontappprocess frontAppProcess F m   4 5 � ��                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  ��  ��   @  � � � l  � ���������  ��  ��   �  � � � Z   � � � ����� � =  � � � � � o   � ����� 0 didminimize didMinimize � m   � ���
�� boovfals � O   � � � � � O   � � � � � k   � � � �  � � � r   � � � � � 4  � ��� �
�� 
cwin � m   � �����  � o      ���� 0 frontwin frontWin �  � � � r   � � � � � m   � ���
�� boovtrue � n       � � � 1   � ���
�� 
valL � n   � � � � � 4   � ��� �
�� 
attr � m   � � � � � � �  A X M i n i m i z e d � o   � ����� 0 frontwin frontWin �  � � � r   � � � � � n   � � � � � 1   � ���
�� 
pnam � o   � ����� 0 frontwin frontWin � o      ���� ,0 minimizedwindowtitle minimizedWindowTitle �  � � � r   � � � � � b   � � � � � b   � � � � � b   � � � � � b   � � � � � b   � � � � � b   � � � � � l  � � ����� � c   � � � � � l  � � ����� � I  � �������
�� .misccurdldt    ��� null��  ��  ��  ��   � m   � ���
�� 
TEXT��  ��   � m   � � � � � � �    |   � o   � ����� 0 frontappname frontAppName � m   � � � � � � �    |   � n   � � � � � 1   � ���
�� 
pnam � o   � ����� 0 frontwin frontWin � 1   � ���
�� 
lnfd � o   � ���
�� 
ret  � o      ���� 0 logentry logEntry �  ��� � r   � � � � � m   � ���
�� boovtrue � o      ���� 0 didminimize didMinimize��   � o   � ����� "0 frontappprocess frontAppProcess � m   � � � ��                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  ��  ��   �  � � � l  � ���������  ��  ��   �  � � � Z   �� � ����� � =  � � � � � o   � ����� 0 didminimize didMinimize � m   � ���
�� boovfals � O   �� � � � Q  � � ��� � Z  � � ��� � � ?   � � � l  ����� � I �� ���
�� .corecnte****       **** � 2 ��
�� 
cwin��  ��  ��   � m  ����   � k  � � �  � � � r   � � � m  �
� boovtrue � n       � � � 1  �~
�~ 
pmnd � 4 �} �
�} 
cwin � m  �|�|  �  � � � r   � � � m  �{
�{ boovtrue � o      �z�z 0 didminimize didMinimize �  � � � l   �y � ��y   � A ; Step 3: Log the minimized window's details to the log file    � � � � v   S t e p   3 :   L o g   t h e   m i n i m i z e d   w i n d o w ' s   d e t a i l s   t o   t h e   l o g   f i l e �  � � � r   F � � � b   B � � � b   > � � � b   : �  � b   3 b   / b   - l  )�x�w c   )	 l  %
�v�u
 I  %�t�s�r
�t .misccurdldt    ��� null�s  �r  �v  �u  	 m  %(�q
�q 
TEXT�x  �w   m  ), �    |   o  -.�p�p 0 frontappname frontAppName m  /2 �    |    n  39 1  79�o
�o 
pnam 4 37�n
�n 
cwin m  56�m�m  � 1  :=�l
�l 
lnfd � o  >A�k
�k 
ret  � o      �j�j 0 logentry logEntry � �i Q  G� k  Jz  l JJ�h�h   ' ! Append the log entry to the file    � B   A p p e n d   t h e   l o g   e n t r y   t o   t h e   f i l e  r  J\ I JX�g !
�g .rdwropenshor       file  4  JP�f"
�f 
file" o  NO�e�e 0 logfilepath logFilePath! �d#�c
�d 
perm# m  ST�b
�b boovtrue�c   o      �a�a  0 filedescriptor fileDescriptor $%$ I ]r�`&'
�` .rdwrwritnull���     ****& o  ]`�_�_ 0 logentry logEntry' �^()
�^ 
refn( o  cf�]�]  0 filedescriptor fileDescriptor) �\*�[
�\ 
wrat* m  il�Z
�Z rdwreof �[  % +�Y+ I sz�X,�W
�X .rdwrclosnull���     ****, o  sv�V�V  0 filedescriptor fileDescriptor�W  �Y   R      �U-.
�U .ascrerr ****      � ****- o      �T�T 0 errmsg errMsg. �S/�R
�S 
errn/ o      �Q�Q 0 errnum errNum�R   k  ��00 121 Q  ��34�P3 I ���O5�N
�O .rdwrclosnull���     ****5 4  ���M6
�M 
file6 o  ���L�L 0 logfilepath logFilePath�N  4 R      �K�J�I
�K .ascrerr ****      � ****�J  �I  �P  2 7�H7 I ���G89
�G .sysonotfnull��� ��� TEXT8 b  ��:;: m  ��<< �== : F a i l e d   t o   w r i t e   t o   l o g   f i l e :  ; o  ���F�F 0 errmsg errMsg9 �E>�D
�E 
appr> m  ��?? �@@  L o g g i n g   E r r o r�D  �H  �i  ��   � k  ��AA BCB I ���CDE
�C .sysonotfnull��� ��� TEXTD m  ��FF �GG j T h e   f r o n t m o s t   a p p l i c a t i o n   h a s   n o   w i n d o w s   t o   m i n i m i z e .E �BH�A
�B 
apprH m  ��II �JJ  M i n i m i z e   W i n d o w�A  C K�@K l ��LMNL L  ���?�?  M * $ Exit if there's nothing to minimize   N �OO H   E x i t   i f   t h e r e ' s   n o t h i n g   t o   m i n i m i z e�@   � R      �>�=�<
�> .ascrerr ****      � ****�=  �<  ��   � 4   � ��;P
�; 
cappP o   � ��:�: 0 frontappname frontAppName��  ��   � QRQ l ���9�8�7�9  �8  �7  R STS l ���6�5�4�6  �5  �4  T UVU Z  ��WX�3�2W = ��YZY o  ���1�1 0 didminimize didMinimizeZ m  ���0
�0 boovfalsX I ���/[�.
�/ .sysonotfnull��� ��� TEXT[ m  ��\\ �]] & F a i l e d   t o   m i n i m i z e !�.  �3  �2  V ^_^ l ���-�,�+�-  �,  �+  _ `a` l ���*bc�*  b @ : Step 3: Define a list of common applications to switch to   c �dd t   S t e p   3 :   D e f i n e   a   l i s t   o f   c o m m o n   a p p l i c a t i o n s   t o   s w i t c h   t oa efe r  ��ghg J  ��ii jkj m  ��ll �mm  F i n d e rk non m  ��pp �qq  S a f a r io rsr m  ��tt �uu  T e r m i n a ls vwv m  ��xx �yy  G o o g l e   C h r o m ew z{z m  ��|| �}}  M a i l{ ~~ m  ���� ���  S p o t i f y ��� m  ���� ���  M s t y� ��)� m  ���� ���  O b s i d i a n�)  h o      �(�( 0 preferredapps preferredAppsf ��� l ���'�&�%�'  �&  �%  � ��� l ���$���$  � D > Initialize a flag to track if a suitable application is found   � ��� |   I n i t i a l i z e   a   f l a g   t o   t r a c k   i f   a   s u i t a b l e   a p p l i c a t i o n   i s   f o u n d� ��� r  ���� m  ���#
�# boovfals� o      �"�" 0 appfound appFound� ��� l �!� ��!  �   �  � ��� l ����  � 1 + Iterate through each preferred application   � ��� V   I t e r a t e   t h r o u g h   e a c h   p r e f e r r e d   a p p l i c a t i o n� ��� X  _���� Q  Z���� O  Q��� Z  %P����� = %,��� n  %*��� 1  &*�
� 
prun�  g  %&� m  *+�
� boovtrue� Z  /L����� ?  /8��� l /6���� I /6���
� .corecnte****       ****� 2 /2�
� 
cwin�  �  �  � m  67��  � k  ;H�� ��� I ;@���
� .miscactvnull��� ��� null�  �  � ��� r  AF��� m  AB�
� boovtrue� o      �� 0 appfound appFound� ��� l GH����  S  GH� ( " Exit once an application is found   � ��� D   E x i t   o n c e   a n   a p p l i c a t i o n   i s   f o u n d�  �  �  �  �  � 4  "�
�
�
 
capp� o   !�	�	 0 appname appName� R      ���
� .ascrerr ****      � ****�  �  � k  YY�� ��� l YY����  � M G Handle applications that might not support AppleScript window commands   � ��� �   H a n d l e   a p p l i c a t i o n s   t h a t   m i g h t   n o t   s u p p o r t   A p p l e S c r i p t   w i n d o w   c o m m a n d s� ��� l YY����  � ' ! Continue to the next application   � ��� B   C o n t i n u e   t o   t h e   n e x t   a p p l i c a t i o n�  � 0 appname appName� o  	�� 0 preferredapps preferredApps� ��� l ``�� ���  �   ��  � ��� l ``������  � ] W Step 4: If no preferred application is found, iterate through all running applications   � ��� �   S t e p   4 :   I f   n o   p r e f e r r e d   a p p l i c a t i o n   i s   f o u n d ,   i t e r a t e   t h r o u g h   a l l   r u n n i n g   a p p l i c a t i o n s� ��� Z  `�������� H  `d�� o  `c���� 0 appfound appFound� k  g��� ��� O  g���� r  k���� 6k���� 2 kn��
�� 
pcap� F  o���� = py��� 1  qu��
�� 
pvis� m  vx��
�� boovtrue� > z���� 1  {}��
�� 
pnam� o  ~����� 0 frontappname frontAppName� o      ���� "0 allappprocesses allAppProcesses� m  gh���                                                                                  sevs  alis    \  Macintosh HD               �&�BD ����System Events.app                                              �����&�        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  � ��� l ����������  ��  ��  � ���� X  ������� k  ���� ��� r  ����� n  ����� 1  ����
�� 
pnam� o  ������ 0 proc  � o      ���� 0 appname appName� ��� l ����������  ��  ��  � ���� Q  ������ O  ����� Z  ��������� ?  ����� l �������� I �������
�� .corecnte****       ****� 2 ����
�� 
cwin��  ��  ��  � m  ������  � k  ���� ��� I ��������
�� .miscactvnull��� ��� null��  ��  �    r  �� m  ����
�� boovtrue o      ���� 0 appfound appFound ��  S  ����  ��  ��  � 4  ����
�� 
capp o  ������ 0 appname appName� R      ������
�� .ascrerr ****      � ****��  ��  � l ������   G A Skip applications that don't support AppleScript window commands    � �   S k i p   a p p l i c a t i o n s   t h a t   d o n ' t   s u p p o r t   A p p l e S c r i p t   w i n d o w   c o m m a n d s��  �� 0 proc  � o  ������ "0 allappprocesses allAppProcesses��  ��  ��  � 	
	 l ����������  ��  ��  
  l ������   F @ Step 5: Handle the case where no suitable application was found    � �   S t e p   5 :   H a n d l e   t h e   c a s e   w h e r e   n o   s u i t a b l e   a p p l i c a t i o n   w a s   f o u n d  Z  ������ H  �� o  ������ 0 appfound appFound I ����
�� .sysonotfnull��� ��� TEXT m  �� � | N o   o t h e r   a p p l i c a t i o n s   w i t h   o p e n   w i n d o w s   f o u n d   t o   s w i t c h   f o c u s . ����
�� 
appr m  �� �  S w i t c h   F o c u s��  ��  ��   �� l ����������  ��  ��  ��    R      ��
�� .ascrerr ****      � **** o      ���� 0 errmsg errMsg ����
�� 
errn o      ���� 0 errnum errNum��    k     !"! l ��#$��  # . ( Handle any unexpected errors gracefully   $ �%% P   H a n d l e   a n y   u n e x p e c t e d   e r r o r s   g r a c e f u l l y" &��& I ��'(
�� .sysodisAaleR        TEXT' m  )) �** H E r r o r   M i n i m i z i n g   a n d   S w i t c h i n g   F o c u s( ��+,
�� 
mesS+ o  
���� 0 errmsg errMsg, ��-��
�� 
as A- m  ��
�� EAlTwarN��  ��  ��  ��    .��. l     ��������  ��  ��  ��       ��/0123��4567����������������  / ��������������������������������
�� .aevtoappnull  �   � ****�� 0 logfilepath logFilePath�� "0 frontappprocess frontAppProcess�� 0 frontappname frontAppName�� 0 didminimize didMinimize�� 0 frontwin frontWin�� ,0 minimizedwindowtitle minimizedWindowTitle�� 0 logentry logEntry�� 0 preferredapps preferredApps�� 0 appfound appFound��  ��  ��  ��  ��  ��  0 ��8����9:��
�� .aevtoappnull  �   � ****8 k    ;;  
<<  ����  ��  ��  9 ���������� 0 errmsg errMsg�� 0 errnum errNum�� 0 appname appName�� 0 proc  : T�������� �� 6��=���������������� c�� l�������� � ���~�}�| ��{ � ��z�y�x�w�v�u�t�s�r�q�p�o�n�m>�l�k<�j?�iFI\lptx|����h�g�f�e�d�c�b�a�`)�_�^�]�\
�� afdrcusr
�� 
rtyp
�� 
ctxt
�� .earsffdralis        afdr�� 0 logfilepath logFilePath
�� 
pcap=  
�� 
pisf�� "0 frontappprocess frontAppProcess
�� 
pnam�� 0 frontappname frontAppName�� 0 didminimize didMinimize
�� 
cwin�� 0 frontwin frontWin
�� 
butT
�� .coredoexnull���     ****
�� .prcsclicnull��� ��� uiel�� ,0 minimizedwindowtitle minimizedWindowTitle
�� .misccurdldt    ��� null
�� 
TEXT
� 
lnfd
�~ 
ret �} 0 logentry logEntry
�| 
attr
�{ 
valL
�z 
capp
�y .corecnte****       ****
�x 
pmnd
�w 
file
�v 
perm
�u .rdwropenshor       file�t  0 filedescriptor fileDescriptor
�s 
refn
�r 
wrat
�q rdwreof �p 
�o .rdwrwritnull���     ****
�n .rdwrclosnull���     ****�m 0 errmsg errMsg> �[�Z�Y
�[ 
errn�Z 0 errnum errNum�Y  �l  �k  
�j 
appr
�i .sysonotfnull��� ��� TEXT�h �g 0 preferredapps preferredApps�f 0 appfound appFound
�e 
kocl
�d 
cobj
�c 
prun
�b .miscactvnull��� ��� null
�a 
pvis�` "0 allappprocesses allAppProcesses
�_ 
mesS
�^ 
as A
�] EAlTwarN
�\ .sysodisAaleR        TEXT�����l �%E�O�� *�k/�[�,\Ze81E�O��,E�UOfE�O�f  e� ]� X*�k/E�O�a a /j  A�a a /j O��,E` O*j a &a %�%a %��,%_ %_ %E` OeE�Y hUUY hO�f  T� L� G*�k/E�Oe�a a /a ,FO��,E` O*j a &a  %�%a !%��,%_ %_ %E` OeE�UUY hO�f  �*a "�/ � �*�-j #j �e*�k/a $,FOeE�O*j a &a %%�%a &%*�k/�,%_ %_ %E` O 5*a '�/a (el )E` *O_ a +_ *a ,a -a . /O_ *j 0W -X 1 2 *a '�/j 0W X 3 4hOa 5�%a 6a 7l 8Y a 9a 6a :l 8OhW X 3 4hUY hO�f  a ;j 8Y hOa <a =a >a ?a @a Aa Ba Ca DvE` EOfE` FO [_ E[a Ga Hl #kh  :*a "�/ -*a I,e  "*�-j #j *j JOeE` FOY hY hUW X 3 4h[OY��O_ F {� *�-�[[a K,\Ze8\[�,\Z�9A1E` LUO S_ L[a Ga Hl #kh ��,E�O ,*a "�/ *�-j #j *j JOeE` FOY hUW X 3 4h[OY��Y hO_ F a Ma 6a Nl 8Y hOPW X 1 2a Oa P�a Qa Ra . S1 �?? j M a c i n t o s h   H D : U s e r s : w a l l s t o p : m i n i m i z e d _ w i n d o w s _ l o g . t x t2 @@  6�XA
�X 
pcapA �BB  S p o t i f y3 �CC  S p o t i f y
�� boovtrue4 DD E�WFE  6�VG
�V 
pcapG �HH  S p o t i f y
�W 
cwinF �II 2 K i n g d o m   O f   G i a n t s   -   S m o k e5 �JJ 2 K i n g d o m   O f   G i a n t s   -   S m o k e6 �KK � S a t u r d a y ,   N o v e m b e r   2 ,   2 0 2 4   a t   8 : 2 7 : 4 5 / P M   |   S p o t i f y   |   K i n g d o m   O f   G i a n t s   -   S m o k e 
 7 �UL�U L  lptx|���
�� boovtrue��  ��  ��  ��  ��  ��  ascr  ��ޭ