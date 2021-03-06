//
//  LocationUtils.swift
//  SeeThere
//
//  Created by Cameron Little on 1/31/15.
//  Copyright (c) 2015 Cameron Little. All rights reserved.
//

import Foundation
import CoreLocation

private let HEIGHT_TOLERANCE: Double = -10
private let MAX_DISTANCE: Double = 50000
private let MIN_DISTANCE: Double = 20
private let DISTANCE_STEP: Double = 10
private let SLOPE_FACTOR: Double = 0.02

func radians(degrees: Double) -> Double {
    return degrees * (M_PI / 180)
}
func degrees(radians: Double) -> Double {
    return radians * (180 / M_PI)
}

func getElevationAt(coordinate: CLLocationCoordinate2D) -> CLLocationDistance? {
    if !CLLocationCoordinate2DIsValid(coordinate) {
        return nil
    }
    
    let reqURL = NSURL(string: "https://maps.googleapis.com/maps/api/elevation/json?key=\(googleAPIKey)&locations=\(coordinate.latitude),\(coordinate.longitude)")
    let request = NSURLRequest(URL: reqURL!)
    
    var error: NSError?
    var response: NSURLResponse?
    var data = NSURLConnection.sendSynchronousRequest(request, returningResponse: &response, error: &error)
    if error != nil {
        return nil
    }
    
    if (data!.length > 0) {
        var responseData: AnyObject? = NSJSONSerialization.JSONObjectWithData(data!, options: NSJSONReadingOptions(0), error: &error)
        
        if responseData?.objectForKey("status") as! String == "OK" {
            var results = responseData?.objectForKey("results") as? [AnyObject]
            var elevation = results?[0].objectForKey("elevation") as! Double
            return elevation
        } else if responseData?.objectForKey("status") as! String == "OVER_QUERY_LIMIT" {
            return getElevationAt(coordinate)
        }
    }
    
    return nil
}

/* Get a list of locations, with altitude information between a start point and an end point.
 * Returned locations will be DISTANCE_STEP apart.
 *
 */
func getElevationPath(start: CLLocation, end: CLLocation) -> ([CLLocation], NSError?) {
    var ret: [CLLocation] = []
    
    let dist = start.distanceFromLocation(end)
    //let samples = min(Int(dist / DISTANCE_STEP), 512)
    let samples = Int(dist / DISTANCE_STEP)
    if samples > 512 {
        return ([], NSError(domain: "getElevationPath start and end too far apart.", code: 4, userInfo: nil))
    }
    
    let reqURLString = "https://maps.googleapis.com/maps/api/elevation/json?key=\(googleAPIKey)&path=\(start.coordinate.latitude),\(start.coordinate.longitude)%7C\(end.coordinate.latitude),\(end.coordinate.longitude)&samples=\(samples)"
    let reqURL = NSURL(string: reqURLString)
    let request = NSURLRequest(URL: reqURL!)
    
    var error: NSError?
    var response: NSURLResponse?
    var data = NSURLConnection.sendSynchronousRequest(request, returningResponse: &response, error: &error)
    if error != nil {
        //return nil
        return (ret, error)
    }
    
    if (data!.length > 0) {
        var responseData: AnyObject? = NSJSONSerialization.JSONObjectWithData(data!, options: NSJSONReadingOptions(0), error: &error)
        if responseData?.objectForKey("status") as! String == "OK" {
            var results = responseData?.objectForKey("results") as? [AnyObject]
            let now = NSDate()
            for loc in results! {
                let rawLocation: AnyObject? = loc.objectForKey("location")
                let coord = CLLocationCoordinate2D(latitude: rawLocation!.objectForKey("lat") as! Double, longitude: rawLocation!.objectForKey("lng") as! Double)
                let elev = loc.objectForKey("elevation") as! Double
                let location = CLLocation(coordinate: coord, altitude: elev, horizontalAccuracy: 0, verticalAccuracy: 0, timestamp: now)
                ret.append(location)
            }
        } else if responseData?.objectForKey("status") as! String == "OVER_QUERY_LIMIT" {
            return getElevationPath(start, end)
        }
    } else {
        return (ret, NSError(domain: "no data received", code: 1, userInfo: nil))
    }
    
    return (ret, nil)
}

func estimateElevation(distance: CLLocationDistance, startAltitude: CLLocationDistance, pitch: Double) -> CLLocationDistance {
    let heightDiff: CLLocationDistance = distance * tan(pitch)
    return startAltitude + heightDiff
}

func newLocation(start: CLLocation, distance: CLLocationDistance, direction: CLLocationDirection) -> CLLocation {
    let startLat = radians(start.coordinate.latitude)
    let startLng = radians(start.coordinate.longitude)

    let dir = radians(direction)
    
    let sinStartLat = sin(startLat)
    let cosStartLat = cos(startLat)
    
    let earthRadius: CLLocationDistance = 6367.4447 * 1000 // meters
    let scaledDistance = distance / earthRadius
    
    let finLat = asin((sinStartLat * cos(scaledDistance)) + (cosStartLat * sin(scaledDistance) * cos(dir)))
    let finLng = startLng + atan2(sin(dir) * sin(scaledDistance) * cosStartLat, cos(scaledDistance) - sinStartLat * sin(finLat))
    
    return CLLocation(latitude: degrees(finLat), longitude: degrees(finLng))
}

func walkOutFrom(start: CLLocation, direction: CLLocationDirection, pitch: Double, operation: NSOperation) -> (CLLocation?, NSError?) {
    var distance = DISTANCE_STEP * 512
    var from = newLocation(start, MIN_DISTANCE, direction)
    println("starting at elevation: \(start.altitude), pitch: \(pitch)")
    let adjAlt = start.altitude + abs(start.verticalAccuracy) // should be positive, but I'll check anyway

    var lastElev: CLLocationDistance = start.altitude

    var minDiff = Double.infinity
    var minLoc = start

    while distance < MAX_DISTANCE {
        // fetch a set of points
        let to = newLocation(start, distance, direction)
        
        let (pathLocs, error) = getElevationPath(from, to)
        if error != nil {
            return (nil, NSError(domain: NSLocalizedString("FailedGoogleElev", comment: "couldn't get data from google api"), code: 2, userInfo: nil))
        }

        if operation.cancelled {
            return (nil, NSError(domain: NSLocalizedString("FailedCancelled", comment: "cancelled"), code: 0, userInfo: nil))
        }
        
        for loc in pathLocs {
            let estimate = estimateElevation(loc.distanceFromLocation(start), adjAlt, pitch)
            let actual = loc.altitude
            let diff = estimate - actual
            let slopeAngle = tan((actual - lastElev) / DISTANCE_STEP)

            println(" distance: \(loc.distanceFromLocation(start))")
            println("  estimate: \(estimate), actual: \(actual), diff: \(diff)")
            println("  slope: \(slopeAngle)")

            /* the slope logic
             * Looking out at something in the distance, often you will be looking
             * along ground parallel with your pitch. To prevent intersections due
             * to inaccuracies in elevation/altitude data, the intersection point
             * needs to be along a slope that's not too parallel to the pitch or 
             * is significantly different in elevation.
             */
            if actual >= 0 &&
                diff < HEIGHT_TOLERANCE &&
                ((slopeAngle - pitch > SLOPE_FACTOR) || (diff < 4 * HEIGHT_TOLERANCE))
                {
                return (loc, nil)
            }

            lastElev = actual

            if minDiff > diff {
                minDiff = diff
                minLoc = loc
            }
        }
        
        distance += DISTANCE_STEP * 512
        from = to
    }

    return (minLoc, NSError(domain: "Falling back to closest vertical point.", code: 0, userInfo: nil))

    // return (nil, NSError(domain: NSLocalizedString("FailedLocationMessage", comment: "no location found"), code: 1, userInfo: nil))
}
