#!/bin/bash

URL="https://hook.us2.make.com/gek4m77f2ngtonw5a3ae2i7kq79k7io2"
DATA='{"Call ID":"a80d2da0-9389-4820-8685-117df7d377cf","Call Time":"2025-01-23T22:40:23.948Z","Pacific Time":"2025-01-23 14:40:23","Phone number":"19254284696","Customer Name":"SAM","Order Details":"1. LG Combination Pizza ($38.95)\n2. Greek Salad ($9.95)","Order Number":"62","Row number":"122","Ended Reason":"customer-ended-call"}'

for i in {1..100}
do
  echo $i
  echo curl -X POST $URL -H "Content-Type: application/json" -d "$DATA"
done

