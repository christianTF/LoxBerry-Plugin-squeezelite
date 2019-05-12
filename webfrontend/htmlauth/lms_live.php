<?php
	
	if($_GET["action"] == "read") {
		$datafile = "/dev/shm/lms2udp_data.json";
		header('Content-Type: application/json; charset=UTF-8');
		echo file_get_contents( $datafile );
		exit;
	}

require_once "loxberry_web.php";
LBWeb::lbheader("Live View", undef, undef);

?>


<style>

th, td {
  border-bottom: 1px solid #ddd;
  padding: 5px;
  text-align: left;
  
}

</style>

<div style="display:flex;flex-wrap:wrap;" id="flexcontainer">
</div>

<script>

var updateRunning = 0;

$( document ).ready(function() {
	updateView();
	setInterval(updateView, 500);	
});

function updateView() {
	// if (getSelectedText()) {
		// // console.log("Text is selected");
		// return; }
	// if (updateRunning) return;
	
	updateRunning = 1;
	$.get( 'lms_live.php?action=read')
	.done(function(resp) {
		// console.log( "ajax_post", "success", resp );
		// if (getSelectedText()) {
			// console.log("Text is selected");
		// return; }
		generate_list(resp);
})
  .fail(function(resp) {
		console.log( "ajax_get", "failed", resp );
  })
  .always(function(resp) {
		// console.log( "ajax_post", "finished", resp );
		updateRunning = 0;
  });
}

function generate_list(resp) {
	var data = resp.States;
	// console.log("generate_list", data);
	var container = $("#flexcontainer");
	//for each (var player in data) {
	tableStr  = '<table style="width:100%";>';
	tableStr += '<tr>';
	tableStr += '<th>Connected</th>';
	tableStr += '<th>Player</th>';
	tableStr += '<th>Power</th>';
	tableStr += '<th>Pause</th>';
	tableStr += '<th>Mode</th>';
	tableStr += '<th>Songtitle</th>';
	tableStr += '<th>Artist</th>';
	tableStr += '<th>Volume</th>';
	tableStr += '<th>Repeat</th>';
	tableStr += '<th>Shuffle</th>';
	tableStr += '<th>Stream</th>';
	tableStr += '<th>Syncgroup</th>';
	tableStr += '</tr>';
	
	var playerStr = "";
	$.each(data, function( player, value) {
		var partnersArray = [];
			
		// Get names of syncgroup
		if (value.sync != null && value.sync != undefined) {
			var syncPartners = value.sync.split(',');
			syncPartners.forEach(function(partner) {
				// console.log("Partner", partner);
				if( data[partner].Name !== 'undefined' ) {
					partnersArray.push(data[partner].Name);
				} else {
					partnersArray.push(partner);
				}
			});
		}
		
		if(value.Power == 1) {
			nameStr = '<span style="color:green"><b>'+value.Name+'</b></span>';
			SongtitleStr = '<b>'+value.Songtitle+'</b>';
		} else {
			nameStr = '<span style="color:darkred">'+value.Name+'</span>';
			SongtitleStr = value.Songtitle;
		}
		
		if(value.Artist == null) 
			value.Artist = "";
				
		playerStr += '<tr>';
		// playerContainer = '<div style="display:flex;flex-wrap:wrap;flex-basis:100%;">'
		playerStr += '<td>'+value.Connected+'</td>';
		playerStr += '<td>'+nameStr+' ('+player+')</td>';
		playerStr += '<td>'+value.Power+'</td>';
		playerStr += '<td>'+value.Pause+'</td>';
		playerStr += '<td>'+value.Mode+'</td>';
		playerStr += '<td>'+SongtitleStr+'</td>';
		playerStr += '<td>'+value.Artist+'</td>';
		playerStr += '<td>'+value.volume+'</td>';
		playerStr += '<td>'+value.Repeat+'</td>';
		playerStr += '<td>'+value.Shuffle+'</td>';
		playerStr += '<td>'+value.Stream+'</td>';
		//playerStr += '<td style="font-size:70%">'+value.sync+'</td>';
		playerStr += '<td style="font-size:70%">'+partnersArray.join(', ')+'</td>';
		playerStr += '</tr>';
		
		console.log(playerStr);
		//container.append(playerStr);
	});
	container.empty();
	container.append(tableStr + playerStr + '</table>');
	
	
}


</script>

<?php
//LBWeb::lbfooter();
