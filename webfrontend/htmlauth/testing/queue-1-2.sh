#!/bin/bash
echo lmsgtw tts --player \"DEVFront\" --text=\"Sabine, gehen wir einen Kaffee trinken?\" | telnet localhost 9092
sleep 0.5
echo lmsgtw tts --player \"DEVrear\" --text=\"Die dümmsten Bauern haben die dicksten Kartoffel\!\" | telnet localhost 9092

