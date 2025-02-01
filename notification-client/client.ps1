# Define WebSocket URL and Client ID
$wsUrl = "wss://voiceful.azurewebsites.net:443"  
$clientId = "Test-Location"      

# Path to the notification sound file
$SoundFile = Join-Path -Path $PSScriptRoot -ChildPath "sounds/single.wav"

# Declare $cancellation globally to make it accessible in On-Open
$cancellation = New-Object System.Threading.CancellationTokenSource

# Import required assemblies for GUI
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide the PowerShell console window
Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public class Win32 {
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();
    }
"@
$consolePtr = [Win32]::GetConsoleWindow()
# 0 = SW_HIDE
[Win32]::ShowWindow($consolePtr, 0)

# Create a NotifyIcon (System Tray Icon)
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Visible = $true
$notifyIcon.Text = "Voiceful Order Client"

# Create Context Menu for the NotifyIcon
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip

# Add "Exit" option to the context menu
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({
    # Cleanup before exiting
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    $cancellation.Cancel()
    Dispose-Runspace
    [System.Windows.Forms.Application]::Exit()
})
$contextMenu.Items.Add($exitItem) | Out-Null

$notifyIcon.ContextMenuStrip = $contextMenu

# Path to the log file
$LogFile = (Join-Path $Env:USERPROFILE "\Desktop\voiceful-client.log")

# Initialize the log file
function Initialize-Log {
    if (-not (Test-Path $LogFile)) {
        New-Item -Path $LogFile -ItemType File -Force | Out-Null
    }
}

# Function to log messages
function Log {
    param (
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $Message"
    Add-Content -Path $LogFile -Value $logMessage
}

# Function to start WebSocket connection in a separate runspace
function Start-WebSocket-Runspace {
    if (-not $global:websocketRunspace) {
        $global:websocketRunspace = [runspacefactory]::CreateRunspace()
        $global:websocketRunspace.Open()
        $powershell = [powershell]::Create().AddScript({
            param($wsUrl, $clientId, $LogFile, $cancellation, $notifyIcon, $soundFile)
            
            # Import required assemblies inside runspace
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            
            # Function to log messages
            function Log {
                param (
                    [string]$Message
                )
                $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                $logMessage = "$timestamp - $Message"
                Add-Content -Path $LogFile -Value $logMessage
            }
    
            # Function to display system notification
            function Show-SystemNotification {
                param (
                    [string]$Title,
                    [string]$Message
                )
                try {
                    $notifyIcon.BalloonTipTitle = $Title
                    $notifyIcon.BalloonTipText = $Message
                    $notifyIcon.ShowBalloonTip(5000)
                } catch {
                    Log "Failed to display system notification: $_"
                }
            }
    
            # Function to play sound notification
            function Play-NotificationSound {
                try {
                    $SoundPlayer = New-Object System.Media.SoundPlayer
                    $SoundPlayer.SoundLocation = $soundFile
                    $SoundPlayer.PlaySync()
                } catch {
                    Log "Failed to play sound notification: $_"
                }
            }

            # Function to handle incoming messages
            function On-Message {
                param ($sender, $e)
                try {
                    # Log the raw message content for debugging
                    Log "Raw message received: $($e.Message)"
                    
                    # Attempt to parse the message as JSON
                    $data = $e.Message | ConvertFrom-Json
                    
                    # Validate the presence of required fields
                    if ($data -and $data.from -and $data.text) {
                        $senderName = $data.from
                        $text = $data.text
                        Log "Notification from ${senderName}: $text"
                        
                        # Show system notification
                        Show-SystemNotification -Title "Voiceful Order" -Message "$text"

                        # Play notification sound
                        Play-NotificationSound
                    }
                    else {
                        Log "Received message with missing fields."
                    }
                } catch {
                    Log "Received invalid JSON message: $_"
                }
            }
    
            # Function to handle errors
            function On-Error {
                param ($sender, $e)
                Log "WebSocket Error: $($e.Exception.Message)"
            }
    
            # Function to handle closure
            function On-Close {
                param ($sender, $e)
                Log "WebSocket closed. Attempting to reconnect in 5 seconds..."
                Start-Sleep -Seconds 5
                Start-WebSocket
            }
    
            # Function to handle open event
            function On-Open {
                param ($sender, $e)
                Log "WebSocket connection established."
                $registration = @{ type = "registration"; clientId = $clientId } | ConvertTo-Json
                
                try {
                    $sender.SendAsync(
                        [System.Text.Encoding]::UTF8.GetBytes($registration), 
                        [System.Net.WebSockets.WebSocketMessageType]::Text, 
                        $true, 
                        [System.Threading.CancellationToken]::None
                    ).Wait()
                    Log "Registered with clientId: $clientId"
                } catch {
                    Log "Failed to send registration message: $_"
                }
            }
    
            # Function to start WebSocket connection
            function Start-WebSocket {
                try {        
                    $websocket = New-Object System.Net.WebSockets.ClientWebSocket
    
                    # Start the connection
                    $connectionTask = $websocket.ConnectAsync($wsUrl, $cancellation.Token)
    
                    # Wait for the connection to establish
                    $connectionTask.Wait()
    
                    if ($websocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                        On-Open -sender $websocket -e $null
    
                        # Receive loop
                        while ($websocket.State -eq [System.Net.WebSockets.WebSocketState]::Open -and -not $cancellation.Token.IsCancellationRequested) {
                            $buffer = New-Object Byte[] 4096
                            $segment = [System.ArraySegment[byte]]::new($buffer, 0, $buffer.Length)
                            $receiveTask = $websocket.ReceiveAsync($segment, $cancellation.Token)
                            $receiveTask.Wait()
                            if ($receiveTask.Result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                                try {
                                    $websocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", $cancellation.Token).Wait()
                                    Log "WebSocket connection closed gracefully."
                                } catch {
                                    Log "Error during WebSocket closure: $_"
                                }
                            } else {
                                $receivedData = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receiveTask.Result.Count)
                                On-Message -sender $websocket -e @{ Message = $receivedData }
                            }
                        }
                    }
                } catch {
                    Log "Exception: $($_.Exception.Message)"
                    Log "Reconnecting in 5 seconds..."
                    Start-Sleep -Seconds 5
                    Start-WebSocket
                }
            }
            
            # Start WebSocket connection
            Start-WebSocket
        }).AddArgument($wsUrl).AddArgument($clientId).AddArgument($LogFile).AddArgument($cancellation).AddArgument($notifyIcon).AddArgument($SoundFile)
        
        $powershell.Runspace = $runspace
        $powershell.BeginInvoke() | Out-Null
    }
}

# Function to dispose runspace on exit
function Dispose-Runspace {
    if ($global:websocketRunspace) {
        $global:websocketRunspace.Close()
        $global:websocketRunspace.Dispose()
        Remove-Variable websocketRunspace -Scope Global
        Log "Runspace disposed."
    }
}

# Initialize logging
Initialize-Log
Log "Client script started."

# Start the WebSocket connection in a separate runspace
Start-WebSocket-Runspace

# Start the Windows Forms Application to keep the NotifyIcon responsive
[System.Windows.Forms.Application]::Run()
