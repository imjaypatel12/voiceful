# Define WebSocket URL and Client ID
$wsUrl = "wss://voiceful.azurewebsites.net:443"  
$clientId = "Test-Location"      

# Path to the notification sound file
$SoundFile = Join-Path -Path $PSScriptRoot -ChildPath "notification.wav"

# Declare $cancellation globally to make it accessible in On-Open
$cancellation = New-Object System.Threading.CancellationTokenSource

# Function to play sound
function Play-NotificationSound {
    if (Test-Path $SoundFile) {
        Add-Type -AssemblyName PresentationCore
        $player = New-Object System.Windows.Media.MediaPlayer
        $player.Open($SoundFile)
        $player.Play()
    } else {
        Write-Host "Sound file not found: $SoundFile"
    }
}

# Function to display system notification
function Show-SystemNotification {
    param (
        [string]$Title,
        [string]$Message
    )
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SystemInformation]
    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon = [System.Drawing.SystemIcons]::Information
    $notify.BalloonTipTitle = $Title
    $notify.BalloonTipText = $Message
    $notify.Visible = $true
    $notify.ShowBalloonTip(5000)
    Start-Sleep -Seconds 5
    $notify.Dispose()
}

# Function to handle incoming messages
function On-Message {
    param ($sender, $e)
    try {
        $data = $e.Message | ConvertFrom-Json
        $senderName = $data.from
        $text = $data.text
        Write-Host "Notification from ${senderName}: $text"
        
        # Play notification sound
        # Play-NotificationSound
        
        # Show system notification
        Show-SystemNotification -Title "Voiceful Order" -Message "$text"
        
    } catch {
        Write-Host "Received invalid JSON message."
    }
}

# Function to handle errors
function On-Error {
    param ($sender, $e)
    Write-Host "WebSocket Error: $($e.Exception.Message)"
}

# Function to handle closure
function On-Close {
    param ($sender, $e)
    Write-Host "WebSocket closed. Attempting to reconnect in 5 seconds..."
    Start-Sleep -Seconds 5
    Start-WebSocket
}

# Function to handle open event
function On-Open {
    param ($sender, $e)
    Write-Host "WebSocket connection established."
    $registration = @{ type = "registration"; clientId = $clientId } | ConvertTo-Json
    
    # Convert registration message to byte array
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($registration)
    
    # Correct instantiation of ArraySegment<byte> with buffer, offset, and count
    $segment = [System.ArraySegment[byte]]::new($buffer, 0, $buffer.Length)
    
    # Send the registration message asynchronously
    $sendTask = $sender.SendAsync(
        $segment, 
        [System.Net.WebSockets.WebSocketMessageType]::Text, 
        $true, 
        $cancellation.Token
    )
    $sendTask.Wait()
    
    Write-Host "Registered with clientId: $clientId"
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
            while ($websocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $buffer = New-Object Byte[] 4096
                $segment = [System.ArraySegment[byte]]::new($buffer, 0, $buffer.Length)
                $receiveTask = $websocket.ReceiveAsync($segment, $cancellation.Token)
                $receiveTask.Wait()
                if ($receiveTask.Result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    $websocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "Closing", $cancellation.Token).Wait()
                } else {
                    $receivedData = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receiveTask.Result.Count)
                    On-Message -sender $websocket -e @{ Message = $receivedData }
                }
            }
        }
    } catch {
        Write-Host "Exception: $($_.Exception.Message)"
        Write-Host "Reconnecting in 5 seconds..."
        Start-Sleep -Seconds 5
        Start-WebSocket
    }
}

# Start the WebSocket connection
Start-WebSocket

# Keep the script running
while ($true) {
    Start-Sleep -Seconds 60
}