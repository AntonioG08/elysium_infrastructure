variable "bucket_name_suffix" {
    description = "Globally unique suffix of the S3 bucket"
    type        = string 
    nullable    = false
}

variable "name_prefix" {
    description = "Prefix for naming the resources"
    type        = string
}

variable "enable_versioning" {
    description = "Whether to enable versioning for objects in the bucket"
    type        = bool
    default     = false
}

variable "is_public" {
    description = "Make the S3 bucket public if true, private if false"
    type        = bool
    default     = false
}

variable "force_destroy" {
    description = "Whether to allow terraform to delete a non-empty bucket"
    type        = bool 
    default     = false
}

variable "enable_intelligent_tiering" {
    description = "Enable S3 Intelligent Tiering for the bucket"
    type        = bool
    default     = false
}

variable "additional_tags" {
    description = "Additional tags specific to this bucket"
    type        = map(string)
    default     = {}
}