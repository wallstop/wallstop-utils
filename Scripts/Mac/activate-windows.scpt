FasdUAS 1.101.10   ��   ��    k             l     ��  ��    N H Script to Restore the Last Minimized Window from Log (Version Improved)     � 	 	 �   S c r i p t   t o   R e s t o r e   t h e   L a s t   M i n i m i z e d   W i n d o w   f r o m   L o g   ( V e r s i o n   I m p r o v e d )   
  
 l     ��������  ��  ��        l     ��  ��    R L ---------------------------------------------------------------------------     �   �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -      l     ��  ��    J D Handler to trim leading/trailing whitespace and common line endings     �   �   H a n d l e r   t o   t r i m   l e a d i n g / t r a i l i n g   w h i t e s p a c e   a n d   c o m m o n   l i n e   e n d i n g s      l     ��  ��    R L ---------------------------------------------------------------------------     �   �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -      i         I      �� ����  0 trimwhitespace trimWhitespace    ��   o      ���� 0 thetext theText��  ��    k     � ! !  " # " l     �� $ %��   $   Handle edge cases first    % � & & 0   H a n d l e   e d g e   c a s e s   f i r s t #  ' ( ' Z     ) *���� ) =     + , + o     ���� 0 thetext theText , m    ��
�� 
msng * L     - - m    ��
�� 
msng��  ��   (  . / . Z    0 1���� 0 =    2 3 2 o    ���� 0 thetext theText 3 m     4 4 � 5 5   1 L     6 6 m     7 7 � 8 8  ��  ��   /  9 : 9 l   ��������  ��  ��   :  ; < ; r     = > = o    ���� 0 thetext theText > o      ���� 0 	cleantext 	cleanText <  ? @ ? Q    � A B C A k   ! � D D  E F E l  ! !�� G H��   G   Trim leading spaces    H � I I (   T r i m   l e a d i n g   s p a c e s F  J K J V   ! J L M L k   ) E N N  O P O l  ) 7 Q R S Q Z  ) 7 T U���� T =   ) . V W V n   ) , X Y X 1   * ,��
�� 
leng Y o   ) *���� 0 	cleantext 	cleanText W m   , -����  U L   1 3 Z Z m   1 2 [ [ � \ \  ��  ��   R   String was just a space    S � ] ] 0   S t r i n g   w a s   j u s t   a   s p a c e P  ^�� ^ r   8 E _ ` _ n   8 C a b a 7  9 C�� c d
�� 
ctxt c m   = ?����  d m   @ B������ b o   8 9���� 0 	cleantext 	cleanText ` o      ���� 0 	cleantext 	cleanText��   M C   % ( e f e o   % &���� 0 	cleantext 	cleanText f m   & ' g g � h h    K  i j i l  K K��������  ��  ��   j  k l k l  K K�� m n��   m P J Trim trailing whitespace (spaces, returns, linefeeds) using a single loop    n � o o �   T r i m   t r a i l i n g   w h i t e s p a c e   ( s p a c e s ,   r e t u r n s ,   l i n e f e e d s )   u s i n g   a   s i n g l e   l o o p l  p q p V   K � r s r k   c  t t  u v u l  c q w x y w Z  c q z {���� z =   c h | } | n   c f ~  ~ 1   d f��
�� 
leng  o   c d���� 0 	cleantext 	cleanText } m   f g����  { L   k m � � m   k l � � � � �  ��  ��   x / ) String was just the whitespace character    y � � � R   S t r i n g   w a s   j u s t   t h e   w h i t e s p a c e   c h a r a c t e r v  ��� � r   r  � � � n   r } � � � 7  s }�� � �
�� 
ctxt � m   w y����  � m   z |������ � o   r s���� 0 	cleantext 	cleanText � o      ���� 0 	cleantext 	cleanText��   s G   O b � � � G   O Z � � � D   O R � � � o   O P���� 0 	cleantext 	cleanText � m   P Q � � � � �    � D   U X � � � o   U V���� 0 	cleantext 	cleanText � o   V W��
�� 
ret  � D   ] ` � � � o   ] ^���� 0 	cleantext 	cleanText � 1   ^ _��
�� 
lnfd q  ��� � l  � ���������  ��  ��  ��   B R      �� � �
�� .ascrerr ****      � **** � o      ���� 0 
errmsgtrim 
errMsgTrim � �� ���
�� 
errn � o      ���� 0 
errnumtrim 
errNumTrim��   C k   � � � �  � � � l  � ��� � ���   � ; 5 Log error and return original text if trimming fails    � � � � j   L o g   e r r o r   a n d   r e t u r n   o r i g i n a l   t e x t   i f   t r i m m i n g   f a i l s �  � � � I  � ��� ���
�� .ascrcmnt****      � **** � b   � � � � � b   � � � � � b   � � � � � b   � � � � � b   � � � � � b   � � � � � m   � � � � � � � N E r r o r   d u r i n g   t r i m W h i t e s p a c e   f o r   t e x t   ' [ � o   � ����� 0 thetext theText � m   � � � � � � �  ] ' :   � o   � ����� 0 
errmsgtrim 
errMsgTrim � m   � � � � � � �    ( � o   � ����� 0 
errnumtrim 
errNumTrim � m   � � � � � � �  )��   �  ��� � L   � � � � o   � ����� 0 thetext theText��   @  � � � l  � ���������  ��  ��   �  ��� � L   � � � � o   � ����� 0 	cleantext 	cleanText��     � � � l     ��������  ��  ��   �  � � � l     ��������  ��  ��   �  � � � l     �� � ���   � R L ---------------------------------------------------------------------------    � � � � �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - �  � � � l     �� � ���   �   Main Restore Logic    � � � � &   M a i n   R e s t o r e   L o g i c �  � � � l     �� � ���   � R L ---------------------------------------------------------------------------    � � � � �   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - �  � � � l     �� � ���   � G A Define the path to the log file (must match the minimize script)    � � � � �   D e f i n e   t h e   p a t h   t o   t h e   l o g   f i l e   ( m u s t   m a t c h   t h e   m i n i m i z e   s c r i p t ) �  � � � l     ����� � r      � � � b     	 � � � l     ����� � I    �� � �
�� .earsffdralis        afdr � m     ��
�� afdrcusr � �� ���
�� 
rtyp � m    ��
�� 
ctxt��  ��  ��   � m     � � � � � 2 m i n i m i z e d _ w i n d o w s _ l o g . t x t � o      ���� 0 logfilepath logFilePath��  ��   �  � � � l     ��������  ��  ��   �  � � � l     �� � ���   � "  Flags for tracking progress    � � � � 8   F l a g s   f o r   t r a c k i n g   p r o g r e s s �  � � � l    ����� � r     � � � m    ��
�� boovfals � o      ���� 0 
didrestore 
didRestore��  ��   �  � � � l    ����� � r     � � � J    ����   � o      ���� 0 loglines logLines��  ��   �  � � � l    ����� � r     � � � m    ������ � o      ���� (0 lineindextorestore lineIndexToRestore��  ��   �  � � � l     ��������  ��  ��   �  � � � l     �� � ���   � > 8 Error handling for file operations and script execution    � � � � p   E r r o r   h a n d l i n g   f o r   f i l e   o p e r a t i o n s   a n d   s c r i p t   e x e c u t i o n �  ��  l  ����� Q   � k   �  l   ��	��   #  Check if the log file exists   	 �

 :   C h e c k   i f   t h e   l o g   f i l e   e x i s t s  O    = Z     <���� H     ) l    (��� I    (�~�}
�~ .coredoexnull���     **** 4     $�|
�| 
file o   " #�{�{ 0 logfilepath logFilePath�}  ��  �   k   , 8  I  , 5�z
�z .sysonotfnull��� ��� TEXT b   , / m   , - � . L o g   f i l e   n o t   f o u n d   a t :   o   - .�y�y 0 logfilepath logFilePath �x�w
�x 
appr m   0 1 �    R e s t o r e   E r r o r�w   !�v! L   6 8�u�u  �v  ��  ��   m    ""�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��   #$# l  > >�t�s�r�t  �s  �r  $ %&% l  > >�q'(�q  '    Read the log file content   ( �)) 4   R e a d   t h e   l o g   f i l e   c o n t e n t& *+* r   > J,-, I  > F�p.�o
�p .rdwrread****        ****. 4   > B�n/
�n 
file/ o   @ A�m�m 0 logfilepath logFilePath�o  - o      �l�l 0 filecontent fileContent+ 010 l  K K�k�j�i�k  �j  �i  1 232 l  K K�h45�h  4 0 * Split the content into lines (paragraphs)   5 �66 T   S p l i t   t h e   c o n t e n t   i n t o   l i n e s   ( p a r a g r a p h s )3 787 r   K T9:9 n   K R;<; 2  N R�g
�g 
cpar< o   K N�f�f 0 filecontent fileContent: o      �e�e 0 loglines logLines8 =>= l  U U�d�c�b�d  �c  �b  > ?@? l  U U�aAB�a  A J D Remove any empty lines at the end (often happens with file writing)   B �CC �   R e m o v e   a n y   e m p t y   l i n e s   a t   t h e   e n d   ( o f t e n   h a p p e n s   w i t h   f i l e   w r i t i n g )@ DED Z   U �FG�`�_F ?   U \HIH l  U ZJ�^�]J I  U Z�\K�[
�\ .corecnte****       ****K o   U V�Z�Z 0 loglines logLines�[  �^  �]  I m   Z [�Y�Y  G V   _ �LML r   | �NON n   | �PQP 7  } ��XRS
�X 
cobjR m   � ��W�W S m   � ��V�V��Q o   | }�U�U 0 loglines logLinesO o      �T�T 0 loglines logLinesM F   c {TUT ?   c jVWV l  c hX�S�RX I  c h�QY�P
�Q .corecnte****       ****Y o   c d�O�O 0 loglines logLines�P  �S  �R  W m   h i�N�N  U =  m wZ[Z n   m s\]\ 4  n s�M^
�M 
cobj^ m   q r�L�L��] o   m n�K�K 0 loglines logLines[ m   s v__ �``  �`  �_  E aba l  � ��J�I�H�J  �I  �H  b cdc l  � ��Gef�G  e + % If the log file is effectively empty   f �gg J   I f   t h e   l o g   f i l e   i s   e f f e c t i v e l y   e m p t yd hih Z   � �jk�F�Ej =  � �lml l  � �n�D�Cn I  � ��Bo�A
�B .corecnte****       ****o o   � ��@�@ 0 loglines logLines�A  �D  �C  m m   � ��?�?  k L   � ��>�>  �F  �E  i pqp l  � ��=�<�;�=  �<  �;  q rsr I  � ��:t�9
�: .ascrcmnt****      � ****t b   � �uvu b   � �wxw m   � �yy �zz  F o u n d  x l  � �{�8�7{ I  � ��6|�5
�6 .corecnte****       ****| o   � ��4�4 0 loglines logLines�5  �8  �7  v m   � �}} �~~ d   l i n e s   i n   l o g   f i l e .   P r o c e s s i n g   l a s t   e n t r y   f i r s t . . .�9  s � l  � ��3�2�1�3  �2  �1  � ��� l  � ��0���0  � > 8 Iterate through the log lines from LAST to FIRST (LIFO)   � ��� p   I t e r a t e   t h r o u g h   t h e   l o g   l i n e s   f r o m   L A S T   t o   F I R S T   ( L I F O )� ��� l  ������ Y   ����/���.� k   ���� ��� r   � ���� [   � ���� \   � ���� l  � ���-�,� I  � ��+��*
�+ .corecnte****       ****� o   � ��)�) 0 loglines logLines�*  �-  �,  � o   � ��(�( 0 i  � m   � ��'�' � o      �&�& 0 logindex logIndex� ��� r   � ���� n   � ���� 4   � ��%�
�% 
cobj� o   � ��$�$ 0 logindex logIndex� o   � ��#�# 0 loglines logLines� o      �"�" 0 currentline currentLine� ��� Z   � ���!� � =  � ���� o   � ��� 0 currentline currentLine� m   � ��� ���  � k   � ��� ��� I  � ����
� .ascrcmnt****      � ****� b   � ���� m   � ��� ��� : S k i p p i n g   e m p t y   l i n e   a t   i n d e x  � o   � ��� 0 logindex logIndex�  � ��� l  � ����� o   � ��� 0 till TILL�   Skip this iteration   � ��� (   S k i p   t h i s   i t e r a t i o n�  �!  �   � ��� l ����  �  �  � ��� l ����  �   Parse the log line   � ��� &   P a r s e   t h e   l o g   l i n e� ��� Q  ����� k  ��� ��� r  ��� m  �� ���    |  � n     ��� 1  
�
� 
txdl� 1  
�
� 
ascr� ��� r  ��� n  ��� 2 �
� 
citm� o  �� 0 currentline currentLine� o      �� 0 logparts logParts� ��� l '���� r  '��� m  �� ���  � n     ��� 1  "&�
� 
txdl� 1  "�
� 
ascr�   Reset delimiters   � ��� "   R e s e t   d e l i m i t e r s� ��� l ((����  �  �  � ��� Z  (S����
� > (1��� l (/��	�� I (/���
� .corecnte****       ****� o  (+�� 0 logparts logParts�  �	  �  � m  /0�� � k  4O�� ��� I 4K���
� .ascrcmnt****      � ****� b  4G��� b  4C��� b  4?��� b  4;��� m  47�� ��� B S k i p p i n g   m a l f o r m e d   l i n e   a t   i n d e x  � o  7:�� 0 logindex logIndex� m  ;>�� ���  :   [� o  ?B� �  0 currentline currentLine� m  CF�� ���  ]�  � ���� l LO���� o  LO���� 0 till TILL�   Skip this iteration   � ��� (   S k i p   t h i s   i t e r a t i o n��  �  �
  � ��� l TT��� ��  � %  Trim parsed parts for accuracy     � >   T r i m   p a r s e d   p a r t s   f o r   a c c u r a c y�  r  Te n Ta I  Ua������  0 trimwhitespace trimWhitespace 	��	 n  U]

 4  X]��
�� 
citm m  [\����  o  UX���� 0 logparts logParts��  ��    f  TU o      ���� 0 loggedappname loggedAppName  r  fw n fs I  gs������  0 trimwhitespace trimWhitespace �� n  go 4  jo��
�� 
citm m  mn����  o  gj���� 0 logparts logParts��  ��    f  fg o      ���� &0 loggedwindowtitle loggedWindowTitle  l xx��������  ��  ��    l xx����   1 + Log exactly what was parsed after trimming    � V   L o g   e x a c t l y   w h a t   w a s   p a r s e d   a f t e r   t r i m m i n g   I x���!��
�� .ascrcmnt****      � ****! b  x�"#" b  x�$%$ b  x�&'& b  x�()( b  x�*+* b  x},-, m  x{.. �// " P r o c e s s i n g   E n t r y  - o  {|���� 0 i  + m  }�00 �11    -   A p p :   [) o  ������ 0 loggedappname loggedAppName' m  ��22 �33  ] ,   T i t l e :   [% o  ������ &0 loggedwindowtitle loggedWindowTitle# m  ��44 �55  ]��    676 l ����������  ��  ��  7 898 l ����:;��  : > 8 Check if the identified application is actually running   ; �<< p   C h e c k   i f   t h e   i d e n t i f i e d   a p p l i c a t i o n   i s   a c t u a l l y   r u n n i n g9 =>= O  ��?@? Z  ��AB����A H  ��CC l ��D����D I ����E��
�� .coredoexnull���     ****E 4  ����F
�� 
pcapF o  ������ 0 loggedappname loggedAppName��  ��  ��  B k  ��GG HIH I ����J��
�� .ascrcmnt****      � ****J b  ��KLK b  ��MNM m  ��OO �PP 2 A p p l i c a t i o n   n o t   r u n n i n g :  N o  ������ 0 loggedappname loggedAppNameL m  ��QQ �RR " .   S k i p p i n g   e n t r y .��  I S��S l ��TUVT o  ������ 0 till TILLU 0 * Skip: Cannot restore if app isn't running   V �WW T   S k i p :   C a n n o t   r e s t o r e   i f   a p p   i s n ' t   r u n n i n g��  ��  ��  @ m  ��XX�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  > YZY l ����������  ��  ��  Z [\[ l ����]^��  ] = 7 Find the target window (with special Spotify handling)   ^ �__ n   F i n d   t h e   t a r g e t   w i n d o w   ( w i t h   s p e c i a l   S p o t i f y   h a n d l i n g )\ `a` l ��bcdb r  ��efe m  ����
�� 
msngf o      ���� 0 targetwindow targetWindowc &   Reset target for this iteration   d �gg @   R e s e t   t a r g e t   f o r   t h i s   i t e r a t i o na hih l ����������  ��  ��  i j��j l ��klmk O  ��non l ��pqrp Z  ��st��us H  ��vv l ��w����w I ����x��
�� .coredoexnull���     ****x 4  ����y
�� 
pcapy o  ������ 0 loggedappname loggedAppName��  ��  ��  t k  ��zz {|{ I ����}��
�� .ascrcmnt****      � ****} b  ��~~ b  ����� m  ���� ��� 2 A p p l i c a t i o n   n o t   r u n n i n g :  � o  ������ 0 loggedappname loggedAppName m  ���� ��� " .   S k i p p i n g   e n t r y .��  | ���� l ������ o  ������ 0 till TILL�   Or 'continue repeat'   � ��� *   O r   ' c o n t i n u e   r e p e a t '��  ��  u k  ���� ��� l ��������  � 4 . App is running, proceed with restore attempts   � ��� \   A p p   i s   r u n n i n g ,   p r o c e e d   w i t h   r e s t o r e   a t t e m p t s� ��� l ����������  ��  ��  � ��� l ������ r  ����� m  ����
�� boovfals� o      ���� >0 windowrestoredinthisiteration windowRestoredInThisIteration� * $ Track success within this iteration   � ��� H   T r a c k   s u c c e s s   w i t h i n   t h i s   i t e r a t i o n� ��� l ����������  ��  ��  � ��� l ��������  � : 4 *** Method 1: Try System Events First (Generic) ***   � ��� h   * * *   M e t h o d   1 :   T r y   S y s t e m   E v e n t s   F i r s t   ( G e n e r i c )   * * *� ��� I ������
�� .ascrcmnt****      � ****� m  ���� ��� :   - >   A t t e m p t   1   ( S y s t e m   E v e n t s )��  � ��� Q  ����� k  ��� ��� r  ��� m  	��
�� 
msng� o      ���� "0 targetwindowref targetWindowRef� ��� l ���� r  ��� b  ��� b  ��� m  �� ���  [� o  ���� &0 loggedwindowtitle loggedWindowTitle� m  �� ���  ]� o      ���� $0 targetwindowname targetWindowName�   Default name   � ���    D e f a u l t   n a m e� ��� l ��������  ��  ��  � ��� l ����� O  ���� l "����� O  "���� l -����� k  -��� ��� l --��������  ��  ��  � ��� l --������  � N H Find *any* minimized window first. Matching title via AX can be tricky.   � ��� �   F i n d   * a n y *   m i n i m i z e d   w i n d o w   f i r s t .   M a t c h i n g   t i t l e   v i a   A X   c a n   b e   t r i c k y .� ��� l --������  � S M You could add 'and name contains loggedWindowTitle' but it might fail often.   � ��� �   Y o u   c o u l d   a d d   ' a n d   n a m e   c o n t a i n s   l o g g e d W i n d o w T i t l e '   b u t   i t   m i g h t   f a i l   o f t e n .� ��� r  -J��� l -F������ 6 -F��� 2  -2��
�� 
cwin� = 5E��� n  6A��� 1  =A��
�� 
valL� 4  6=���
�� 
attr� m  9<�� ���  A X M i n i m i z e d� m  BD��
�� boovtrue��  ��  � o      ���� *0 minimizedwindowsref minimizedWindowsRef� ��� l KK��������  ��  ��  � ���� Z  K������� ?  KT��� l KR������ I KR�����
�� .corecnte****       ****� o  KN���� *0 minimizedwindowsref minimizedWindowsRef��  ��  ��  � m  RS����  � k  W��� ��� r  Wc��� n  W_��� 4  Z_���
�� 
cobj� m  ]^���� � o  WZ���� *0 minimizedwindowsref minimizedWindowsRef� o      ���� "0 targetwindowref targetWindowRef� � � Q  d� r  gr n  gn 1  jn��
�� 
pnam o  gj���� "0 targetwindowref targetWindowRef o      ���� $0 targetwindowname targetWindowName R      ������
�� .ascrerr ****      � ****��  ��   r  z�	 b  z�

 b  z� m  z} �  [ o  }����� &0 loggedwindowtitle loggedWindowTitle m  �� � (   -   N a m e   U n a v a i l a b l e ]	 o      ���� $0 targetwindowname targetWindowName   I ������
�� .ascrcmnt****      � **** b  �� m  �� � \   - >   F o u n d   m i n i m i z e d   w i n d o w   v i a   S y s t e m   E v e n t s :   o  ������ $0 targetwindowname targetWindowName��    l ����������  ��  ��    l ������   4 . Attempt Restore using System Events Attribute    � \   A t t e m p t   R e s t o r e   u s i n g   S y s t e m   E v e n t s   A t t r i b u t e  !  r  ��"#" m  ����
�� boovfals# n      $%$ 1  ����
�� 
valL% n  ��&'& 4  ���(
� 
attr( m  ��)) �**  A X M i n i m i z e d' o  ���~�~ "0 targetwindowref targetWindowRef! +,+ l ��-./- I ���}0�|
�} .sysodelanull��� ��� nmbr0 m  ��11 ?ə������|  .   Allow time for change   / �22 ,   A l l o w   t i m e   f o r   c h a n g e, 343 l ���{�z�y�{  �z  �y  4 565 r  ��787 m  ���x
�x boovtrue8 o      �w�w >0 windowrestoredinthisiteration windowRestoredInThisIteration6 9:9 I ���v;�u
�v .ascrcmnt****      � ****; m  ��<< �== R   - >   R e s t o r e   v i a   S y s t e m   E v e n t s   s u c c e s s f u l .�u  : >�t> l ���s�r�q�s  �r  �q  �t  ��  � I ���p?�o
�p .ascrcmnt****      � ****? m  ��@@ �AA b   - >   N o   m i n i m i z e d   w i n d o w s   f o u n d   v i a   S y s t e m   E v e n t s .�o  ��  � . ( Target the specific application process   � �BB P   T a r g e t   t h e   s p e c i f i c   a p p l i c a t i o n   p r o c e s s� 4  "*�nC
�n 
prcsC o  &)�m�m 0 loggedappname loggedAppName�   process   � �DD    p r o c e s s� m  EE�                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  �   System Events   � �FF    S y s t e m   E v e n t s� G�lG l ���k�j�i�k  �j  �i  �l  � R      �hHI
�h .ascrerr ****      � ****H o      �g�g "0 errmsgsysevents errMsgSysEventsI �fJ�e
�f 
errnJ o      �d�d "0 errnumsysevents errNumSysEvents�e  � k  ��KK LML I ���cN�b
�c .ascrcmnt****      � ****N b  ��OPO b  ��QRQ b  ��STS b  ��UVU m  ��WW �XX B   - >   S y s t e m   E v e n t s   m e t h o d   f a i l e d :  V o  ���a�a "0 errmsgsysevents errMsgSysEventsT m  ��YY �ZZ    (R o  ���`�` "0 errnumsysevents errNumSysEventsP m  ��[[ �\\ 4 ) .   T r y i n g   s t a n d a r d   m e t h o d .�b  M ]�_] l ��^_`^ r  ��aba m  ���^
�^ boovfalsb o      �]�] >0 windowrestoredinthisiteration windowRestoredInThisIteration_ $  Ensure flag is false on error   ` �cc <   E n s u r e   f l a g   i s   f a l s e   o n   e r r o r�_  � ded l ���\�[�Z�\  �[  �Z  e fgf l ���Yhi�Y  h I C *** Method 2: Try Standard AppleScript if System Events Failed ***   i �jj �   * * *   M e t h o d   2 :   T r y   S t a n d a r d   A p p l e S c r i p t   i f   S y s t e m   E v e n t s   F a i l e d   * * *g klk Z  �qmn�X�Wm H  ��oo o  ���V�V >0 windowrestoredinthisiteration windowRestoredInThisIterationn k  �mpp qrq I ���Us�T
�U .ascrcmnt****      � ****s m  ��tt �uu H   - >   A t t e m p t   2   ( S t a n d a r d   A p p l e S c r i p t )�T  r v�Sv Q  �mwxyw k   Lzz {|{ r   }~} m   �R
�R 
msng~ o      �Q�Q 0 targetwindow targetWindow| � l �P�O�N�P  �O  �N  � ��� r  ��� J  �� ��� m  �� ���  S p o t i f y� ��M� m  �� ���  D i s c o r d�M  � o      �L�L .0 appswithdynamictitles appsWithDynamicTitles� ��� l �K�J�I�K  �J  �I  � ��� l �H�G�F�H  �G  �F  � ��� l �E�D�C�E  �D  �C  � ��� l J���� O  J��� k   I�� ��� l  &���� r   &��� J   "�B�B  � o      �A�A 0 targetwindows targetWindows�   Initialize empty list   � ��� ,   I n i t i a l i z e   e m p t y   l i s t� ��� l ''�@�?�>�@  �?  �>  � ��� l ''�=���=  � D > Check if the app needs special title handling in the fallback   � ��� |   C h e c k   i f   t h e   a p p   n e e d s   s p e c i a l   t i t l e   h a n d l i n g   i n   t h e   f a l l b a c k� ��� Z  '����<�� E '.��� o  '*�;�; .0 appswithdynamictitles appsWithDynamicTitles� o  *-�:�: 0 loggedappname loggedAppName� k  1z�� ��� I 1@�9��8
�9 .ascrcmnt****      � ****� b  1<��� b  18��� m  14�� ���    - >   A p p   [� o  47�7�7 0 loggedappname loggedAppName� m  8;�� ��� r ]   u s e s   d y n a m i c   t i t l e s .   F a l l b a c k   w i l l   i g n o r e   l o g g e d   t i t l e .�8  � ��� l AA�6���6  � K E Find *any* minimized window for these apps using standard properties   � ��� �   F i n d   * a n y *   m i n i m i z e d   w i n d o w   f o r   t h e s e   a p p s   u s i n g   s t a n d a r d   p r o p e r t i e s� ��5� Q  Az���� r  DZ��� l DV��4�3� 6 DV��� 2  DI�2
�2 
cwin� = LU��� 1  MQ�1
�1 
pmnd� m  RT�0
�0 boovtrue�4  �3  � o      �/�/ 0 targetwindows targetWindows� R      �.��-
�. .ascrerr ****      � ****� o      �,�, 0 errminicheck errMiniCheck�-  � k  bz�� ��� I bs�+��*
�+ .ascrcmnt****      � ****� b  bo��� b  bm��� b  bi��� m  be�� ��� ^   - >   E r r o r   c h e c k i n g   ' m i n i a t u r i z e d '   p r o p e r t y   f o r  � o  eh�)�) 0 loggedappname loggedAppName� m  il�� ���  :  � o  mn�(�( 0 errminicheck errMiniCheck�*  � ��'� l tz���� r  tz��� J  tv�&�&  � o      �%�% 0 targetwindows targetWindows� $  Ensure list is empty on error   � ��� <   E n s u r e   l i s t   i s   e m p t y   o n   e r r o r�'  �5  �<  � k  }��� ��� I }��$��#
�$ .ascrcmnt****      � ****� b  }���� b  }���� m  }��� ��� h   - >   U s i n g   s t a n d a r d   f a l l b a c k   ( m a t c h i n g   l o g g e d   t i t l e   [� o  ���"�" &0 loggedwindowtitle loggedWindowTitle� m  ���� ���  ] ) .�#  � ��� l ���!���!  � + % Use exact title match for other apps   � ��� J   U s e   e x a c t   t i t l e   m a t c h   f o r   o t h e r   a p p s� �� � Q  ������ r  ����� l ������ 6 ����� 2  ���
� 
cwin� F  ����� = ��� � 1  ���
� 
pnam  o  ���� &0 loggedwindowtitle loggedWindowTitle� = �� 1  ���
� 
pmnd m  ���
� boovtrue�  �  � o      �� 0 targetwindows targetWindows� R      ��
� .ascrerr ****      � **** o      �� $0 errnameminicheck errNameMiniCheck�  � k  ��  I ����
� .ascrcmnt****      � **** b  ��	 b  ��

 b  �� m  �� � x   - >   E r r o r   c h e c k i n g   ' n a m e '   a n d   ' m i n i a t u r i z e d '   p r o p e r t i e s   f o r   o  ���� 0 loggedappname loggedAppName m  �� �  :  	 o  ���� $0 errnameminicheck errNameMiniCheck�   � l �� r  �� J  ����   o      �� 0 targetwindows targetWindows $  Ensure list is empty on error    � <   E n s u r e   l i s t   i s   e m p t y   o n   e r r o r�  �   �  l ������  �  �    l ���
�
   M G Check if any suitable window was found by the appropriate method above    � �   C h e c k   i f   a n y   s u i t a b l e   w i n d o w   w a s   f o u n d   b y   t h e   a p p r o p r i a t e   m e t h o d   a b o v e  �	  Z  �I!"�#! ?  ��$%$ l ��&��& I ���'�
� .corecnte****       ****' o  ���� 0 targetwindows targetWindows�  �  �  % m  ����  " k  �(( )*) l ��+,-+ r  ��./. n  ��010 4  ���2
� 
cobj2 m  ��� �  1 o  ������ 0 targetwindows targetWindows/ o      ���� 0 targetwindow targetWindow, - ' Get the application's window reference   - �33 N   G e t   t h e   a p p l i c a t i o n ' s   w i n d o w   r e f e r e n c e* 454 l ����������  ��  ��  5 676 l ����89��  8 * $ Log which window was actually found   9 �:: H   L o g   w h i c h   w i n d o w   w a s   a c t u a l l y   f o u n d7 ;<; I ���=��
�� .ascrcmnt****      � ****= b  ��>?> b  ��@A@ m  ��BB �CC N   - >   F o u n d   w i n d o w   v i a   S t a n d a r d   m e t h o d :   [A l ��D����D n  ��EFE 1  ����
�� 
pnamF o  ������ 0 targetwindow targetWindow��  ��  ? m  ��GG �HH  ]��  < IJI l ��������  ��  ��  J KLK l ��MN��  M = 7 Attempt Restore using Standard 'miniaturized' property   N �OO n   A t t e m p t   R e s t o r e   u s i n g   S t a n d a r d   ' m i n i a t u r i z e d '   p r o p e r t yL PQP r  RSR m  ��
�� boovfalsS n      TUT 1  
��
�� 
pmndU o  ���� 0 targetwindow targetWindowQ VWV l ��������  ��  ��  W XYX l Z[\Z r  ]^] m  ��
�� boovtrue^ o      ���� >0 windowrestoredinthisiteration windowRestoredInThisIteration[   CORRECTED SYNTAX   \ �__ "   C O R R E C T E D   S Y N T A XY `a` I ��b��
�� .ascrcmnt****      � ****b m  cc �dd `   - >   R e s t o r e   v i a   S t a n d a r d   A p p l e S c r i p t   s u c c e s s f u l .��  a e��e l ��������  ��  ��  ��  �  # k  Iff ghg l ��ij��  i / ) Log failure specific to the method tried   j �kk R   L o g   f a i l u r e   s p e c i f i c   t o   t h e   m e t h o d   t r i e dh l��l Z  Imn��om E %pqp o  !���� .0 appswithdynamictitles appsWithDynamicTitlesq o  !$���� 0 loggedappname loggedAppNamen I (7��r��
�� .ascrcmnt****      � ****r b  (3sts b  (/uvu m  (+ww �xx z   - >   N o   m i n i m i z e d   w i n d o w s   f o u n d   v i a   S t a n d a r d   A p p l e S c r i p t   f o r   [v o  +.���� 0 loggedappname loggedAppNamet m  /2yy �zz  ] .��  ��  o I :I��{��
�� .ascrcmnt****      � ****{ b  :E|}| b  :A~~ m  :=�� ��� T   - >   N o   m i n i m i z e d   w i n d o w   w i t h   e x a c t   t i t l e   [ o  =@���� &0 loggedwindowtitle loggedWindowTitle} m  AD�� ��� B ]   f o u n d   v i a   S t a n d a r d   A p p l e S c r i p t .��  ��  �	  � 4  ���
�� 
capp� o  ���� 0 loggedappname loggedAppName�    application loggedAppName   � ��� 4   a p p l i c a t i o n   l o g g e d A p p N a m e� ���� l KK��������  ��  ��  ��  x R      ����
�� .ascrerr ****      � ****� o      ����  0 errmsgstandard errMsgStandard� �����
�� 
errn� o      ����  0 errnumstandard errNumStandard��  y k  Tm�� ��� I Tg�����
�� .ascrcmnt****      � ****� b  Tc��� b  T_��� b  T]��� b  TY��� m  TW�� ��� P   - >   S t a n d a r d   A p p l e S c r i p t   m e t h o d   f a i l e d :  � o  WX����  0 errmsgstandard errMsgStandard� m  Y\�� ���    (� o  ]^����  0 errnumstandard errNumStandard� m  _b�� ���  )��  � ���� l hm���� r  hm��� m  hi��
�� boovfals� o      ���� >0 windowrestoredinthisiteration windowRestoredInThisIteration� $  Ensure flag is false on error   � ��� <   E n s u r e   f l a g   i s   f a l s e   o n   e r r o r��  �S  �X  �W  l ��� l rr��������  ��  ��  � ��� l rr������  � E ? *** Post-Restore Actions (if successful in this iteration) ***   � ��� ~   * * *   P o s t - R e s t o r e   A c t i o n s   ( i f   s u c c e s s f u l   i n   t h i s   i t e r a t i o n )   * * *� ��� Z  r������� o  ru���� >0 windowrestoredinthisiteration windowRestoredInThisIteration� k  x��� ��� l x{���� r  x{��� m  xy��
�� boovtrue� o      ���� 0 
didrestore 
didRestore� - ' Set the main flag for log update later   � ��� N   S e t   t h e   m a i n   f l a g   f o r   l o g   u p d a t e   l a t e r� ��� l |���� r  |��� o  |}���� 0 i  � o      ���� (0 lineindextorestore lineIndexToRestore� + % Record the 1-based index for removal   � ��� J   R e c o r d   t h e   1 - b a s e d   i n d e x   f o r   r e m o v a l� ��� l ����������  ��  ��  � ��� l ��������  �   Activate the application   � ��� 2   A c t i v a t e   t h e   a p p l i c a t i o n� ��� Q  ������ O ����� I ��������
�� .miscactvnull��� ��� null��  ��  � 4  �����
�� 
capp� o  ������ 0 loggedappname loggedAppName� R      �����
�� .ascrerr ****      � ****� o      ����  0 errmsgactivate errMsgActivate��  � I �������
�� .ascrcmnt****      � ****� b  ����� b  ����� b  ����� m  ���� ��� Z   - >   W a r n i n g :   C o u l d   n o t   a c t i v a t e   a p p l i c a t i o n   '� o  ������ 0 loggedappname loggedAppName� m  ���� ��� " '   a f t e r   r e s t o r e :  � o  ������  0 errmsgactivate errMsgActivate��  � ��� l ����������  ��  ��  � ��� I �������
�� .ascrcmnt****      � ****� b  ����� b  ����� m  ���� ��� b W i n d o w   r e s t o r e d   s u c c e s s f u l l y   f o r   l o g   e n t r y   i n d e x  � o  ������ 0 i  � m  ���� ���  .   E x i t i n g   l o o p .��  � ���� l ������  S  ��� 5 / Exit the main loop once one window is restored   � ��� ^   E x i t   t h e   m a i n   l o o p   o n c e   o n e   w i n d o w   i s   r e s t o r e d��  ��  � I �������
�� .ascrcmnt****      � ****� b  ����� b  ����� m  ���� ��� V   - >   N o   w i n d o w   r e s t o r e d   f o r   l o g   e n t r y   i n d e x  � o  ������ 0 i  � m  ���� ��� 6 .   C h e c k i n g   o l d e r   e n t r i e s . . .��  � ���� l ����������  ��  ��  ��  q "  End check if app is running   r ��� 8   E n d   c h e c k   i f   a p p   i s   r u n n i n go m  �����                                                                                  sevs  alis    \  Macintosh HD               � gBD ����System Events.app                                              ����� g        ����  
 cu             CoreServices  0/:System:Library:CoreServices:System Events.app/  $  S y s t e m   E v e n t s . a p p    M a c i n t o s h   H D  -System/Library/CoreServices/System Events.app   / ��  l $  System Events (for app check)   m ��� <   S y s t e m   E v e n t s   ( f o r   a p p   c h e c k )��  � R      �����
�� .ascrerr ****      � ****� o      ���� (0 errmsgparseorcheck errMsgParseOrCheck��  � k  ���� ��� l ��������  � @ : Error during parsing, trimming, or checking app existence   � �   t   E r r o r   d u r i n g   p a r s i n g ,   t r i m m i n g ,   o r   c h e c k i n g   a p p   e x i s t e n c e�  I ������
�� .ascrcmnt****      � **** b  �� b  �� b  ��	 m  ��

 � 4 E r r o r   p r o c e s s i n g   l o g   l i n e  	 o  ������ 0 i   m  �� �  :   o  ������ (0 errmsgparseorcheck errMsgParseOrCheck��   �� l ������   . ( Continue loop to check next older entry    � P   C o n t i n u e   l o o p   t o   c h e c k   n e x t   o l d e r   e n t r y��  � �� l ����������  ��  ��  ��  �/ 0 i  � m   � ����� � l  � ����� I  � �����
�� .corecnte****       **** o   � ����� 0 loglines logLines��  ��  ��  �.  �    end loop through logLines   � � 4   e n d   l o o p   t h r o u g h   l o g L i n e s�  l ����������  ��  ��    l ������   D > After the loop, if a window was restored, update the log file    � |   A f t e r   t h e   l o o p ,   i f   a   w i n d o w   w a s   r e s t o r e d ,   u p d a t e   t h e   l o g   f i l e  Z  �� !�� F  ��"#" o  ������ 0 
didrestore 
didRestore# > ��$%$ o  ������ (0 lineindextorestore lineIndexToRestore% m  ��������  k  ��&& '(' I ���)�
�� .ascrcmnt****      � ****) m  �** �++ J W i n d o w   r e s t o r e d .   U p d a t i n g   l o g   f i l e . . .�  ( ,-, l �~./�~  . @ : Create the new log content by excluding the restored line   / �00 t   C r e a t e   t h e   n e w   l o g   c o n t e n t   b y   e x c l u d i n g   t h e   r e s t o r e d   l i n e- 121 r  343 m  
55 �66  4 o      �}�} &0 updatedlogcontent updatedLogContent2 787 Y  >9�|:;�{9 Z  9<=�z�y< >  >?> o  �x�x 0 j  ? o  �w�w (0 lineindextorestore lineIndexToRestore= l #5@AB@ r  #5CDC b  #1EFE b  #-GHG o  #&�v�v &0 updatedlogcontent updatedLogContentH l &,I�u�tI n  &,JKJ 4  ',�sL
�s 
cobjL o  *+�r�r 0 j  K o  &'�q�q 0 loglines logLines�u  �t  F o  -0�p
�p 
ret D o      �o�o &0 updatedlogcontent updatedLogContentA a [ Use return or linefeed consistency? Let's use return for simplest text concatenation here.   B �MM �   U s e   r e t u r n   o r   l i n e f e e d   c o n s i s t e n c y ?   L e t ' s   u s e   r e t u r n   f o r   s i m p l e s t   t e x t   c o n c a t e n a t i o n   h e r e .�z  �y  �| 0 j  : m  �n�n ; l N�m�lN I �kO�j
�k .corecnte****       ****O o  �i�i 0 loglines logLines�j  �m  �l  �{  8 PQP l ??�h�g�f�h  �g  �f  Q RSR l ??�eTU�e  T N H Write the updated content back to the file, overwriting the old content   U �VV �   W r i t e   t h e   u p d a t e d   c o n t e n t   b a c k   t o   t h e   f i l e ,   o v e r w r i t i n g   t h e   o l d   c o n t e n tS W�dW Q  ?�XYZX k  B|[[ \]\ r  BR^_^ I BN�c`a
�c .rdwropenshor       file` 4  BF�bb
�b 
fileb o  DE�a�a 0 logfilepath logFilePatha �`c�_
�` 
permc m  IJ�^
�^ boovtrue�_  _ o      �]�]  0 filedescriptor fileDescriptor] ded l S^fghf I S^�\ij
�\ .rdwrseofnull���     ****i o  SV�[�[  0 filedescriptor fileDescriptorj �Zk�Y
�Z 
set2k m  YZ�X�X  �Y  g $  Clear the file before writing   h �ll <   C l e a r   t h e   f i l e   b e f o r e   w r i t i n ge mnm I _l�Wop
�W .rdwrwritnull���     ****o o  _b�V�V &0 updatedlogcontent updatedLogContentp �Uq�T
�U 
refnq o  eh�S�S  0 filedescriptor fileDescriptor�T  n rsr I mt�Rt�Q
�R .rdwrclosnull���     ****t o  mp�P�P  0 filedescriptor fileDescriptor�Q  s u�Ou I u|�Nv�M
�N .ascrcmnt****      � ****v m  uxww �xx " L o g   f i l e   u p d a t e d .�M  �O  Y R      �Ly�K
�L .ascrerr ****      � ****y o      �J�J 0 errmsgwrite errMsgWrite�K  Z k  ��zz {|{ I ���I}~
�I .sysonotfnull��� ��� TEXT} b  ��� m  ���� ��� R F a i l e d   t o   u p d a t e   l o g   f i l e   a f t e r   r e s t o r e :  � o  ���H�H 0 errmsgwrite errMsgWrite~ �G��F
�G 
appr� m  ���� ���  L o g g i n g   E r r o r�F  | ��� I ���E��D
�E .ascrcmnt****      � ****� b  ����� m  ���� ��� 6 F a i l e d   t o   u p d a t e   l o g   f i l e :  � o  ���C�C 0 errmsgwrite errMsgWrite�D  � ��B� Q  �����A� I ���@��?
�@ .rdwrclosnull���     ****� 4  ���>�
�> 
file� o  ���=�= 0 logfilepath logFilePath�?  � R      �<�;�:
�< .ascrerr ****      � ****�;  �:  �A  �B  �d  ! ��� H  ���� o  ���9�9 0 
didrestore 
didRestore� ��8� k  ���� ��� l ���7���7  � ? 9 If the loop finished without restoring anything suitable   � ��� r   I f   t h e   l o o p   f i n i s h e d   w i t h o u t   r e s t o r i n g   a n y t h i n g   s u i t a b l e� ��6� I ���5��4
�5 .ascrcmnt****      � ****� m  ���� ��� � L o o p   f i n i s h e d .   N o   l o g g e d   &   c u r r e n t l y   m i n i m i z e d   w i n d o w s   f o u n d   t o   r e s t o r e .�4  �6  �8  ��   ��3� l ���2�1�0�2  �1  �0  �3   R      �/��
�/ .ascrerr ****      � ****� o      �.�.  0 errmsgtoplevel errMsgTopLevel� �-��,
�- 
errn� o      �+�+ 0 errnum errNum�,   k  ���� ��� l ���*���*  � ( " Catch any top-level script errors   � ��� D   C a t c h   a n y   t o p - l e v e l   s c r i p t   e r r o r s� ��� I ���)��(
�) .ascrcmnt****      � ****� b  ����� b  ����� b  ����� b  ����� m  ���� ��� @ R e s t o r e   S c r i p t   T o p - L e v e l   E r r o r :  � o  ���'�'  0 errmsgtoplevel errMsgTopLevel� m  ���� ���    (� o  ���&�& 0 errnum errNum� m  ���� ���  )�(  � ��%� I ���$��
�$ .sysodisAaleR        TEXT� m  ���� ��� ( R e s t o r e   S c r i p t   E r r o r� �#��
�# 
mesS� b  ����� m  ���� ��� & A n   e r r o r   o c c u r r e d :  � o  ���"�"  0 errmsgtoplevel errMsgTopLevel� �!�� 
�! 
as A� m  ���
� EAlTwarN�   �%  ��  ��  ��       "�����������������������������������  �  �
�	��������� �������������������������������������������
  0 trimwhitespace trimWhitespace
�	 .aevtoappnull  �   � ****� 0 logfilepath logFilePath� 0 
didrestore 
didRestore� 0 loglines logLines� (0 lineindextorestore lineIndexToRestore� 0 filecontent fileContent� 0 logindex logIndex� 0 currentline currentLine� 0 logparts logParts�  0 loggedappname loggedAppName�� &0 loggedwindowtitle loggedWindowTitle�� 0 targetwindow targetWindow�� >0 windowrestoredinthisiteration windowRestoredInThisIteration�� "0 targetwindowref targetWindowRef�� $0 targetwindowname targetWindowName�� *0 minimizedwindowsref minimizedWindowsRef�� &0 updatedlogcontent updatedLogContent��  0 filedescriptor fileDescriptor��  ��  ��  ��  ��  ��  ��  ��  ��  ��  ��  ��  ��  � �� ����������  0 trimwhitespace trimWhitespace�� ����� �  ���� 0 thetext theText��  � ���������� 0 thetext theText�� 0 	cleantext 	cleanText�� 0 
errmsgtrim 
errMsgTrim�� 0 
errnumtrim 
errNumTrim� �� 4 7 g�� [�� ������� ������ � � � ���
�� 
msng
�� 
leng
�� 
ctxt
�� 
ret 
�� 
bool
�� 
lnfd������ 0 
errmsgtrim 
errMsgTrim� ������
�� 
errn�� 0 
errnumtrim 
errNumTrim��  
�� .ascrcmnt****      � ****�� ���  �Y hO��  �Y hO�E�O j (h����,k  �Y hO�[�\[Zl\Zi2E�[OY��O 8h��
 ���&
 ���&��,k  �Y hO�[�\[Zk\Z�2E�[OY��OPW !X  �%a %�%a %�%a %j O�O�� �����������
�� .aevtoappnull  �   � ****� k    ���  ���  ���  ���  ���  ����  ��  ��  � ���������������������������� 0 i  �� "0 errmsgsysevents errMsgSysEvents�� "0 errnumsysevents errNumSysEvents�� 0 errminicheck errMiniCheck�� $0 errnameminicheck errNameMiniCheck��  0 errmsgstandard errMsgStandard��  0 errnumstandard errNumStandard��  0 errmsgactivate errMsgActivate�� (0 errmsgparseorcheck errMsgParseOrCheck�� 0 j  �� 0 errmsgwrite errMsgWrite��  0 errmsgtoplevel errMsgTopLevel�� 0 errnum errNum� ��������� ���������"������������������_����y}�����������������������������.024��OQ���������������������������������)1��<@���WY[t��������������������BGcwy��������������������
*5��������������������w�������������~��}�|�{�z
�� afdrcusr
�� 
rtyp
�� 
ctxt
�� .earsffdralis        afdr�� 0 logfilepath logFilePath�� 0 
didrestore 
didRestore�� 0 loglines logLines�� (0 lineindextorestore lineIndexToRestore
�� 
file
�� .coredoexnull���     ****
�� 
appr
�� .sysonotfnull��� ��� TEXT
�� .rdwrread****        ****�� 0 filecontent fileContent
�� 
cpar
�� .corecnte****       ****
�� 
cobj
�� 
bool����
�� .ascrcmnt****      � ****�� 0 logindex logIndex�� 0 currentline currentLine�� 0 till TILL
�� 
ascr
�� 
txdl
�� 
citm�� 0 logparts logParts��  0 trimwhitespace trimWhitespace�� 0 loggedappname loggedAppName�� &0 loggedwindowtitle loggedWindowTitle
�� 
pcap
�� 
msng�� 0 targetwindow targetWindow�� >0 windowrestoredinthisiteration windowRestoredInThisIteration�� "0 targetwindowref targetWindowRef�� $0 targetwindowname targetWindowName
�� 
prcs
�� 
cwin�  
�� 
attr
�� 
valL�� *0 minimizedwindowsref minimizedWindowsRef
�� 
pnam��  ��  
�� .sysodelanull��� ��� nmbr�� "0 errmsgsysevents errMsgSysEvents� �y�x�w
�y 
errn�x "0 errnumsysevents errNumSysEvents�w  �� .0 appswithdynamictitles appsWithDynamicTitles
�� 
capp�� 0 targetwindows targetWindows
�� 
pmnd�� 0 errminicheck errMiniCheck�� $0 errnameminicheck errNameMiniCheck��  0 errmsgstandard errMsgStandard� �v�u�t
�v 
errn�u  0 errnumstandard errNumStandard�t  
�� .miscactvnull��� ��� null��  0 errmsgactivate errMsgActivate�� (0 errmsgparseorcheck errMsgParseOrCheck�� &0 updatedlogcontent updatedLogContent
�� 
ret 
�� 
perm
�� .rdwropenshor       file��  0 filedescriptor fileDescriptor
�� 
set2
�� .rdwrseofnull���     ****
�� 
refn
�� .rdwrwritnull���     ****
�� .rdwrclosnull���     ****�� 0 errmsgwrite errMsgWrite�  0 errmsgtoplevel errMsgTopLevel� �s�r�q
�s 
errn�r 0 errnum errNum�q  
�~ 
mesS
�} 
as A
�| EAlTwarN�{ 
�z .sysodisAaleR        TEXT������l �%E�OfE�OjvE�OiE�O�� *��/j  ��%��l OhY hUO*��/j E` O_ a -E�O�j j 8 2h�j j	 �a i/a  a &�[a \[Zk\Za 2E�[OY��Y hO�j j  hY hOa �j %a %j O5k�j kh  �j �kE` O�a _ /E` O_ a   a _ %j O_ Y hO�a  _ !a ",FO_ a #-E` $Oa %_ !a ",FO_ $j m  a &_ %a '%_ %a (%j O_ Y hO)_ $a #l/k+ )E` *O)_ $a #m/k+ )E` +Oa ,�%a -%_ *%a .%_ +%a /%j O� )*a 0_ */j  a 1_ *%a 2%j O_ Y hUOa 3E` 4O�*a 0_ */j  a 5_ *%a 6%j O_ Y�fE` 7Oa 8j O �a 3E` 9Oa :_ +%a ;%E` <O� �*a =_ */ �*a >-a ?[a @a A/a B,\Ze81E` CO_ Cj j l_ Ca k/E` 9O _ 9a D,E` <W X E Fa G_ +%a H%E` <Oa I_ <%j Of_ 9a @a J/a B,FOa Kj LOeE` 7Oa Mj OPY 	a Nj UUOPW  X O Pa Q�%a R%�%a S%j OfE` 7O_ 7}a Tj OQa 3E` 4Oa Ua VlvE` WO*a X_ */+jvE` YO_ W_ * Na Z_ *%a [%j O *a >-a ?[a \,\Ze81E` YW X ] Fa ^_ *%a _%�%j OjvE` YY Ya `_ +%a a%j O )*a >-a ?[[a D,\Z_ +8\[a \,\Ze8A1E` YW X b Fa c_ *%a d%�%j OjvE` YO_ Yj j ?_ Ya k/E` 4Oa e_ 4a D,%a f%j Of_ 4a \,FOeE` 7Oa gj OPY -_ W_ * a h_ *%a i%j Y a j_ +%a k%j UOPW  X l ma n�%a o%�%a p%j OfE` 7Y hO_ 7 JeE�O�E�O *a X_ */ *j qUW X r Fa s_ *%a t%�%j Oa u�%a v%j OY a w�%a x%j OPUW X y Fa z�%a {%�%j OPOP[OY��O�	 	�ia & �a |j Oa }E` ~O .k�j kh 	�� _ ~�a �/%_ %E` ~Y h[OY��O ?*��/a �el �E` �O_ �a �jl �O_ ~a �_ �l �O_ �j �Oa �j W 3X � Fa ��%�a �l Oa ��%j O *��/j �W X E FhY � a �j Y hOPW 2X � �a ��%a �%�%a �%j Oa �a �a ��%a �a �a � �� ��� j M a c i n t o s h   H D : U s e r s : w a l l s t o p : m i n i m i z e d _ w i n d o w s _ l o g . t x t
� boovtrue� �p��p �  ��� ��� � F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 7 : 1 8 ? P M   |   T e r m i n a l   |   w a l l s t o p - u t i l s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . a l l s t o p - u t i l s      - z s h      1 2 1 * 3 3� ��� � F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 8 : 2 3 ? P M   |   S p o t i f y   |   A r c h e r s   -   B e t t e r   O f f� � ���� F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 7 : 1 8 ? P M   |   T e r m i n a l   |   w a l l s t o p - u t i l s      w a l l s t o p @ E l i s - M a c B o o k - P r o      . . a l l s t o p - u t i l s      - z s h      1 2 1 * 3 3  F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 8 : 2 3 ? P M   |   S p o t i f y   |   A r c h e r s   -   B e t t e r   O f f 
� � �o��o �  ����n�m�l�k�j�i�h�g�f�e�d�c�b� ��� H F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 8 : 2 3 ? P M� ���  S p o t i f y� ��� ( A r c h e r s   -   B e t t e r   O f f�n  �m  �l  �k  �j  �i  �h  �g  �f  �e  �d  �c  �b  
� 
msng
� boovtrue� �� ��a�� "�`�
�` 
pcap� ���  S p o t i f y
�a 
cwin� ��� * T O O L   -   R o s e t t a   S t o n e d� ��� * T O O L   -   R o s e t t a   S t o n e d� �_��_ �  �� ��� � F r i d a y ,   A p r i l   2 5 ,   2 0 2 5   a t   7 : 4 8 : 2 3 ? P M   |   S p o t i f y   |   A r c h e r s   -   B e t t e r   O f f � �  �  �  �  �  �  �  �  �  �  �  �  �  ascr  ��ޭ