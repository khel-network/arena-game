<?php
// This file receives payment confirmation from ZapUPI

// Get the data ZapUPI sent
$data = json_decode(file_get_contents('php://input'), true);

// Check if payment was successful
if ($data['status'] == 'Success') {
    $amount = $data['amount'];
    $order_id = $data['order_id'];
    
    // Connect to your database
    // Update user's wallet with tokens
    // Example: UPDATE users SET tokens = tokens + ($amount * 2) WHERE order_id = '$order_id'
    
    // Log the payment
    file_put_contents('payments.log', "Payment received: $amount\n", FILE_APPEND);
}

// Tell ZapUPI we received the message
http_response_code(200);
?>
