#!/usr/bin/env bash

OPERATION=$1
STAC_CATALOG_LINK=$2

STAGING_LOCATION=$(echo "$OPERATION"  | jq -r '.stagingLocation')
STAC_CATALOG=$(cat ${STAC_CATALOG_LINK})

ID=$(echo STAC_CATALOG | jq -r '.id')
LINKS=$(echo $STAC_CATALOG | jq -r '.links[] | select(.rel=="item") | .href')
IFS=$'\n' read -rd '' -a LINKS_ARRAY <<< "${LINKS}"
for LINK in "${LINKS_ARRAY[@]}"
do
  # download the STAC item (possibly just a copy from the local fs)
  if [[ $LINK =~ ^[s|S]3.*$ ]]; then
    echo "aws s3 cp ${LINK} stac-item.json"
    aws s3 cp "${LINK}" stac-item.json
  else
    cp "${LINK}" stac-item.json
  fi

  # read and parse the STAC item file
  STAC_ITEM=$(cat stac-item.json)
  DATA_LINK=$(echo "$STAC_ITEM" | jq -r '.assets.granule.href')

  BASENAME=$(basename "$DATA_LINK")
  OUTPUT_LINK="${STAGING_LOCATION}${BASENAME}"

  # copy the file to the S3 staging location
  aws s3 cp "$DATA_LINK" "$OUTPUT_LINK"

  # update the link in the STAC item file to create a new file
  NEW_ITEM=$(echo "$STAC_ITEM" | jq ".assets.granule.href |= \"${OUTPUT_LINK}\"")
  echo "$NEW_ITEM" > stac-item.json

  # copy the new STAC item up to S3
  UUID=$(od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}')
  FILE_NAME="${UUID}.json"
  NEW_ITEM_S3_LINK="${DATA_LINK}${FILE_NAME}"
  aws s3 cp stac-item.json "$NEW_ITEM_S3_LINK"

  # update the STAC catalog to point to the new STAC item in S3
  STAC_CATALOG=$(echo "$STAC_CATALOG" | jq "(.links[] | select(.href==\"${LINK}\") | .href) |= \"${FILE_NAME}\"")

done

echo "${STAC_CATALOG}" > stac-catalog.json

# copy the new STAC catalog up to S3
STAC_CATLOG_S3_LINK="${STAGING_LOCATION}/stac-catalog-${ID}.json"
aws s3 cp stac-catalog.json "${STAC_CATALOG_S3_LINK}"

# send the link to the new STAC catalog to Harmony along with progress data
curl -XPOST \
  --data-urlencode "batch_completed=true" \
  # the number of batches being processed
  --data-urlencode "batch_count={{inputs.parameters.batch-count}}" \
  # the numbrer of steps after batch processing, .e.g., mosaicing steps
  --data-urlencode "post_batch_step_count={{inputs.parameters.post-batch-step-count}}" \
  # the link to the STAC catalog
  --data-urlencode "stac_catalog_link=${STAC_CATALOG_S3_LINK}" \
  "{{inputs.parameters.callback}}/response"