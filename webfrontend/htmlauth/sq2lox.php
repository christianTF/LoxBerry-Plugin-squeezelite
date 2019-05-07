<?php
// Einstellungen LMS
$LMS_Server       = "192.168.xxx.xxx"; //IP des LMS
$LMS_Port         = "9090"; // Port des LMS meist 9090
$MAC              = "xx:xx:xx:xx:xx:xx"; //MAC-Adresse des Players

// Einstellungen MiniServer
$LoxIP            = "192.168.xxx.xxx"; //IP des MiniServer
$LoxUser          = "xxxxxxxxx"; //User des MiniServer
$LoxPass          = "xxxxxxxxx"; //PAsswort des MiniServer
// VI/VTI an die die Werte gesendet werden, nur Zahl ohne VI/VTI eintragen. Sollen Wert nicht übermittelt werden 0 eintragen.
$LoxVTI_Title     = "1"; //VTI fuer Titel und Artist
$LoxVI_Volume     = "22"; //VI fuer Volume
$LoxVTI_Mode      = "0"; //VTI fuer Mode play/stop/pause
$LoxVI_PowerState = "0"; //VI Power

// Einstellungen Telnet Verbindung
$TimeOut          = "10"; //Timeout wenn Telnet nicht erreichbar

//Telnet-Verbindung aufbauen
$telnet           = fsockopen($LMS_Server, $LMS_Port, $errno, $errstr, $TimeOut);
if (!$telnet) {
    echo "Connection failed\n";
    exit();
} else {
    //Abfrage der Daten
    fputs($telnet, "" . $MAC . " artist ? \r\n");
    $artist = fgets($telnet, 1024);
    fputs($telnet, "" . $MAC . " title ? \r\n");
    $title = fgets($telnet, 1024);
    fputs($telnet, "" . $MAC . " mixer volume ? \r\n");
    $volume = fgets($telnet, 128);
    fputs($telnet, "" . $MAC . " mode ? \r\n");
    $mode = fgets($telnet, 128);
    fputs($telnet, "" . $MAC . " power ? \r\n");
    $power = fgets($telnet, 128);
    fputs($telnet, "exit\r\n");

    //Telnet-Ausgabe bearbeiten
    $artist = substr($artist, 35, -2);
    $title  = substr($title, 34, -2);
    $volume = substr($volume, 41, -2);
    $mode   = substr($mode, 33, -2);
    $power  = substr($power, 34, -2);
}
// Wenn kein Artist vorhanden ist wird nur der Titel weitergegeben
// Das ist z.B. bei Internetradio so, dort steht alles immer in der Zeile Titel
if ($artist != "") {
    $title_artist = ($title . "%20/%20" . $artist);
} else {
    $title_artist = $title;
}

//Artist/Titel, Volume, Mode und Powerstate senden
if ($LoxVTI_Title != 0){
$sendtitle = fopen("http://" . $LoxUser . ":" . $LoxPass . "@" . $LoxIP . "/dev/sps/io/VTI" . $LoxVTI_Title . "/" . $title_artist . "", "r");
fclose($sendtitle);
}
if ($LoxVI_Volume != 0){
$sendvolume = fopen("http://" . $LoxUser . ":" . $LoxPass . "@" . $LoxIP . "/dev/sps/io/VI" . $LoxVI_Volume . "/" . $volume . "", "r");
fclose($sendvolume);
}
if ($LoxVTI_Mode != 0){
$sendmode = fopen("http://" . $LoxUser . ":" . $LoxPass . "@" . $LoxIP . "/dev/sps/io/VTI" . $LoxVTI_Mode . "/" . $mode . "", "r");
fclose($sendmode);
}
if ($LoxVI_PowerState != 0){
$sendpower = fopen("http://" . $LoxUser . ":" . $LoxPass . "@" . $LoxIP . "/dev/sps/io/VI" . $LoxVI_PowerState . "/" . $power . "", "r");
fclose($sendpower);
}
?>