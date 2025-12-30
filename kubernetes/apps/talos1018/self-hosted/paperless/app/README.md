# Paperless-ngx

Paperless-ngx is a document management system that transforms your physical documents into a searchable online archive.

## Features

- OCR document processing
- Automatic tagging and classification
- Full-text search
- Mobile-friendly web interface
- Email integration
- Automatic backup to Google Drive

## Google Drive Backup Configuration

To enable automatic backups to Google Drive using rclone:

### 1. Create rclone gdrive configuration

Run the following command to create the gdrive remote with appropriate permissions:

```bash
rclone config create gdrive drive scope=drive
```

This will:
- Create a new rclone remote named `gdrive`
- Use Google Drive as the backend
- Request full drive access scope
- Open your browser for OAuth authentication

### 2. Extract the configuration

After authentication is complete, retrieve the configuration:

```bash
rclone config show gdrive
```

Copy the entire output, which should look similar to:

```
[gdrive]
type = drive
scope = drive
token = {"access_token":"...","token_type":"Bearer",...}
```

### 3. Update the Kubernetes secret

Edit the encrypted secret file using SOPS:

```bash
sops kubernetes/apps/talos1018/self-hosted/paperless/app/paperless-secret.sops.yaml
```

Replace the entire `rclone.conf` value in the `stringData` section with the output from step 2.

The structure should be:

```yaml
stringData:
  rclone.conf: |
    [gdrive]
    type = drive
    scope = drive
    token = {"access_token":"...","token_type":"Bearer",...}
```

Save and close the editor. SOPS will automatically re-encrypt the file.

## Notes

- The rclone token will eventually expire and need to be refreshed
- Ensure the Google Drive account has sufficient storage for backups
- Backups are incremental and run on a scheduled basis
