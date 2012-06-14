<?php
include 'qweb_php/qweb.php';
$xml="base.xml";

$x= new qweb_xml();
$x->load($xml);
$dic= array();
print $x->render("main", $dic)
    

?>