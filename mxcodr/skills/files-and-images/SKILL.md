---
name: files-and-images
description: "Photos, images and documents that users upload, show, download or delete in a Mendix app: the System.Image and System.FileDocument entities, the Marketplace File Uploader, thumbnails and large photos, document lists with name and size, download and delete. Use before building any upload, photo, picture, attachment, document or file feature, and when an image or a file upload does not build or does not show."
---

# Files and images

A Mendix 11 app (React client) uploads, shows and downloads files with a few
fixed parts. Each one below was built, checked with `mx check` and used in the
browser (file-image session, 2026-10-13). Take these; do not search the mxcli
binary or the widget packages for other spellings -- that cost a session a
quarter of an hour.

## 1. The entities

A photo is a specialisation of `System.Image`, a document of `System.FileDocument`,
each owned by the object it belongs to:

```sql
create or modify persistent entity Catalogue.ProductPhoto extends System.Image (
);
create or modify persistent entity Catalogue.ProductDocument extends System.FileDocument (
);
create or modify association Catalogue.Product_Photos
  from Catalogue.ProductPhoto to Catalogue.Product
  type Reference owner Default on delete cascade;
create or modify association Catalogue.Product_Documents
  from Catalogue.ProductDocument to Catalogue.Product
  type Reference owner Default on delete cascade;
```

`Name`, `Size` and `Contents` come from `System.FileDocument`; give the role
`read`/`write` on them like on any attribute (no `write *` on the specialisation:
CE6592).

## 2. Uploading: the Marketplace File Uploader

The project has no upload widget until the File Uploader module is installed
(`imageuploader`, `fileuploader` and `filemanager` are refused before that):

```bash
./mxcli marketplace search "file uploader"        # Mendix, Platform support: id 235351
./mxcli marketplace install 235351 -p App.mpr
./mxcli fix widgets -p App.mpr
```

The install needs `./mxcli auth login`; if the gate says the person must log in,
ask them and wait.

After an exec that writes a `fileuploader`, the hook updates the widgets (`mxcli fix widgets`); without it the build fails with CE0463.

The widget sits in a data view over the owner. It creates each file through a
nanoflow, then commits it on success and deletes it on failure:

```sql
dataview ProductDetail_DocumentsForm (DataSource: $Product) {
  fileuploader ProductDetail_DocumentsUploader (
    uploadMode: 'files',                         -- 'images' + associatedImages + createImageAction for photos
    associatedFiles: $currentObject/Catalogue.Product_Documents,
    createFileAction: nanoflow Catalogue.NF_ProductDocument_Create,
    onUploadSuccessFile: nanoflow Catalogue.NF_ProductDocument_Uploaded,
    onUploadFailureFile: nanoflow Catalogue.NF_ProductDocument_Failed,
    maxFileSize: 25
  ) {
    allowedfileformat pdf (configMode: 'simple', predefinedType: 'pdfFile')
    allowedfileformat word (configMode: 'simple', predefinedType: 'msWordFile')
  }
}
```

```sql
create or modify nanoflow Catalogue.NF_ProductDocument_Create ($Product: Catalogue.Product)
begin
  @caption 'Start the document'
  $Document = create Catalogue.ProductDocument (Product_Documents = $Product) refresh;
  @caption 'Store the document'
  commit $Document refresh;
end;
```

The create nanoflow must create the object: one that returns without creating it
leaves the widget stuck ("did not create any objects within 10 seconds").

## 3. Showing a photo

**Thumbnail and large photo.** Since mxcli 0.27 the Image widget binds to the photo object
in context: put it in a data view, list view or gallery over the `System.Image` specialisation
(or over a `$currentObject` path to it) and size it with `WidthUnit: pixels, Width: 64` for a
list, `320` for a page. Outside a data container, or over an entity that does not extend
`System.Image`, `check` refuses it. The legacy `dynamicimage` is refused in a React-client app (CE0582).

```sql
-- inside the page's data view over the product
listview ProductDetail_PhotosList (DataSource: $currentObject/Catalogue.Product_Photos) {
  image ProductDetail_PhotoImage (Image: $currentObject, WidthUnit: pixels, Width: 64)
}
```

Measured on mxcli 0.27.0 and Mendix 11.12.1: `exec` writes it and `mx check` reports 0 errors. If the
page still shows "No image selected." for a photo that is there, a mxcli older than 0.27 wrote it:
`./mxcli --version`, and the installer's pinned mxcli.

**`ImageType` takes `image`, `imageUrl` or `icon` only.** Another value, such as
`dynamicImage`, is stored without a warning and shows nothing.

## 4. A list of documents: name, size, download, delete

```sql
datagrid ProductDetail_DocumentsGrid (DataSource: $currentObject/Catalogue.Product_Documents) {
  column (Attribute: Name, Caption: 'Name') { textfilter ProductDetail_DocumentNameFilter }
  column (Caption: 'Size', ShowContentAs: dynamicText, DynamicText: '{1}',
          DynamicTextParams: ({1} = toString(ceil($currentObject/Size div 1024)) + ' KB'))
  column (Caption: 'Actions', ShowContentAs: customContent) {
    actionbutton ProductDetail_DocumentDownloadButton (Caption: 'Download',
      Action: call microflow Catalogue.ACT_ProductDocument_Download(Document = $currentObject),
      Icon: 'Atlas_Core.Atlas_Filled.cloud-download')
    actionbutton ProductDetail_DocumentDeleteButton (Caption: 'Delete',
      Action: call microflow Catalogue.ACT_ProductDocument_Delete(Document = $currentObject, Product = $Product),
      Icon: 'Atlas_Core.Atlas_Filled.trash-can')
  }
}
```

MDL divides with `div`, not `/`.

```sql
create or modify microflow Catalogue.ACT_ProductDocument_Download ($Document: Catalogue.ProductDocument)
begin
  @caption 'Offer the document for download'
  download file $Document;
end;

create or modify microflow Catalogue.ACT_ProductDocument_Delete ($Document: Catalogue.ProductDocument, $Product: Catalogue.Product)
begin
  @caption 'Remove the document'
  delete $Document;
  @caption 'Show the product again, with its documents up to date'
  show page Catalogue.Product_Detail (Product = $Product);
end;
```

## 5. Traps

- **Strict mode turns the File Uploader's own Remove off.** It calls
  `mx.data.remove`, which Production security disables. Delete from the grid's row
  button instead, as above.
- **The uploader's custom buttons cannot be written.** Their `buttonIcon` is an
  icon-typed property that mxcli v0.26.0 does not write, and the build fails with
  CE0642 "Property 'Icon' is required." Use the grid's row buttons.
- **A microflow that deletes leaves the row on screen.** MDL has no
  refresh-in-client for `delete`; re-open the page, as `ACT_ProductDocument_Delete`
  does.
- **Uploading on a create form commits the owner.** Committing the new photo
  commits the new product with it, empty name included. Put the uploader on the
  owner's page after it is saved, or accept that the upload saves it.
- **In a browser test, wait for a grid cell's text, not for its row.** The row
  exists before its cells are filled.
